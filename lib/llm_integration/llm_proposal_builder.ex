defmodule Current.LLMProposalBuilder do
  @moduledoc """
  Wires the LLM boundary together: Current.LLMClient (talks to the
  model, owns nothing about Current's vocabulary) -> BlobStore (raw
  response preserved for provenance, always, success or failure) ->
  Current.ProposalDecoder (untrusted bytes -> typed Proposal.t()).

  Producing a proposal is a conversation, not one call. The model is
  given the project's layout (Current.ProjectContext) -- paths and
  sizes, no contents. Each reply is either the proposal, which ends the
  conversation, or a request for context: observations, each wrapping a
  `read_file`, `glob` or `grep` intent, which Current.Observer runs
  under the runtime's file-access rules. The conversation is an
  append-only message list, so each subsequent call includes the model's
  earlier replies as well as the observation results or repair guidance.

  While it works, each round is also reported to Current.ActivityHub --
  what the model asked for, then how each request was settled -- so a
  client can show progress before there is a proposal. That is a live
  view only; the record is the proposal's observations:

  What the model looked at is kept with the proposal: its observations
  (see Current.Observation), in the order it asked, each settled as shown
  or refused. They hold artifact ids, never contents.

  The conversation is bounded three ways:

    * each model call by the timeout WorkflowOrchestrator passes in;
    * the number of context requests by @max_observe_rounds, and how much
      they may return in total by @context_budget_bytes;
    * the whole build -- every call and every read -- by the task's own
      `timeout_ms` when it was submitted with one, else `task_timeout_ms/0`.

  Per Current.ProposalBuilder's @callback contract, this module owns its
  own crash and timeout handling completely -- WorkflowOrchestrator no
  longer enforces either (see start_proposal_production/1). A client
  call that hangs, raises, or returns garbage must never escape this
  module as anything other than {:ok, ...} or
  {:error, %Current.Error.ProposalProductionError{}}.
  """

  @behaviour Current.ProposalBuilder

  alias Current.{
    ActivityHub,
    BlobStore,
    ProjectContext,
    Proposal,
    ProposalDecoder,
    Request,
    Observer,
    LLMPromptBuilder
  }

  alias Current.Error.ProposalProductionError

  @max_repairs 2

  # How long one task's proposal may take in total, however many times
  # the model is called. Hard-coded for now; the application env key is
  # only there so tests don't have to wait this long.
  @task_timeout_ms 600_000

  # How many times the model may ask for context before it has to
  # propose, and how many bytes of results it may be shown in total.
  @max_observe_rounds 8
  @context_budget_bytes 400_000

  @doc """
  The bound on one whole build: every model call and every read between
  them. A build still running after this long is killed and fails at the
  `:timeout` stage.
  """
  @spec task_timeout_ms() :: pos_integer()
  def task_timeout_ms, do: Application.get_env(:current, :llm_task_timeout_ms, @task_timeout_ms)

  @impl true
  @spec build(Request.t(), Current.Id.t(), String.t(), pos_integer(), Path.t() | nil) ::
          {:ok, Proposal.t()}
          | {:ok, Proposal.t(), Current.Id.t()}
          | {:error, ProposalProductionError.t()}
  def build(%Request{} = req, workflow_id, model, timeout_ms, project_dir)
      when is_binary(model) and is_integer(timeout_ms) and timeout_ms > 0 do
    within_task_timeout(req, fn ->
      with {:ok, client} <- client_for(model),
           {:ok, project} <- project_layout(project_dir) do
        converse(%{
          request: req,
          workflow_id: workflow_id,
          model: model,
          client: client,
          call_timeout_ms: timeout_ms,
          project: project,
          messages:
            LLMPromptBuilder.initial_messages(req, project, project_dir, @max_observe_rounds),
          observations: [],
          calls: 0,
          cumulative_usage: nil,
          rounds_left: @max_observe_rounds,
          repairs_left: @max_repairs,
          budget: @context_budget_bytes
        })
      end
    end)
  end

  # The catalog knows which client listed the model.
  defp client_for(model) do
    {:ok, pid} = Current.ModelCatalog.find_supervisor_pid()

    case Current.ModelCatalog.resolve(pid, model) do
      {:ok, client} ->
        {:ok, client}

      :error ->
        {:error,
         %ProposalProductionError{
           stage: :connection,
           reason: {:no_client_for_model, model}
         }}
    end
  end

  defp project_layout(nil) do
    {:error, %ProposalProductionError{stage: :project_context, reason: :no_project_dir}}
  end

  defp project_layout(project_dir) do
    case ProjectContext.layout(project_dir) do
      {:ok, project} ->
        {:ok, project}

      {:error, reason} ->
        {:error, %ProposalProductionError{stage: :project_context, reason: reason}}
    end
  end

  ## --- The whole build, with a bound of its own ------------------------------

  # The conversation runs in a task so the bound holds whatever it is
  # doing when time runs out -- waiting on the model or walking a huge
  # directory for a glob. The per-call task below is linked to this one,
  # so killing this one takes an in-flight model call down with it.
  defp within_task_timeout(%Request{timeout_ms: requested}, build) do
    timeout_ms = requested || task_timeout_ms()
    task = Task.async(fn -> contained(build) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error,
         %ProposalProductionError{
           stage: :timeout,
           reason: "no proposal after #{timeout_ms}ms"
         }}
    end
  end

  ## --- The conversation -----------------------------------------------------

  # One turn: ask, then either finish with the proposal or run what the
  # model asked to see and ask again.
  defp converse(state) do
    case call_with_timeout(
           state.client,
           state.messages,
           state.call_timeout_ms,
           state.model
         ) do
      {:ok, %{text: raw, usage: usage}} ->
        calls = state.calls + 1
        cumulative_usage = add_usage(state.cumulative_usage, usage)

        ActivityHub.llm_responded(
          state.workflow_id,
          calls,
          usage,
          cumulative_usage
        )

        handle_reply(raw, %{
          state
          | messages: LLMPromptBuilder.append_message(state.messages, :assistant, raw),
            calls: calls,
            cumulative_usage: cumulative_usage
        })

      {:error, :timeout} ->
        {:error,
         %ProposalProductionError{
           stage: :timeout,
           reason: "no response after #{state.call_timeout_ms}ms"
         }}

      {:error, reason} ->
        {:error,
         %ProposalProductionError{
           stage: :connection,
           reason: reason
         }}
    end
  end

  ## --- Decode + provenance ------------------------------------------------

  defp handle_reply(raw, state) do
    {:ok, raw_output_blob_id} = BlobStore.put(raw)

    case ProposalDecoder.decode_reply(raw, state.workflow_id) do
      {:ok, {:proposal, %Proposal{} = proposal}} ->
        proposal = %Proposal{proposal | observations: attach(state.observations, proposal)}
        {:ok, proposal, raw_output_blob_id}

      # The last prompt said a proposal was required and got another
      # request instead. Running it would make the limit meaningless.
      {:ok, {:observe, _intents}} when state.rounds_left == 0 ->
        {:error,
         %ProposalProductionError{
           stage: :context_budget,
           reason: "still asking for context after #{@max_observe_rounds} requests",
           raw_output_blob_id: raw_output_blob_id
         }}

      {:ok, {:observe, requested}} ->
        # Which reply asked: this one.
        round = @max_observe_rounds - state.rounds_left + 1

        requested =
          Enum.map(requested, &%{&1 | round: round, reply_artifact_id: raw_output_blob_id})

        # Live progress for whoever is watching this workflow (see
        # Current.ActivityHub). Casts: they never wait, and never fail the build.
        ActivityHub.observe_requested(state.workflow_id, round, requested)

        {made, budget} = Observer.observe(requested, state.project.root, state.budget)
        {observations, texts} = Enum.unzip(made)

        ActivityHub.observe_settled(state.workflow_id, round, made)

        converse(%{
          state
          | observations: state.observations ++ observations,
            messages:
              LLMPromptBuilder.append_message(
                state.messages,
                :user,
                LLMPromptBuilder.observation_message(texts, state.rounds_left - 1)
              ),
            rounds_left: state.rounds_left - 1,
            repairs_left: @max_repairs,
            budget: budget
        })

      {:error, reason} when state.repairs_left > 0 ->
        converse(%{
          state
          | messages:
              LLMPromptBuilder.append_message(
                state.messages,
                :user,
                LLMPromptBuilder.repair_message(reason)
              ),
            repairs_left: state.repairs_left - 1
        })

      {:error, reason} ->
        {:error,
         %ProposalProductionError{
           stage: :decode,
           reason: reason,
           raw_output_blob_id: raw_output_blob_id
         }}
    end
  end

  # Anything raised, thrown or exited from inside the build becomes a
  # result. One line saying what and where is kept: it goes in the event
  # log, and it is what someone needs to find the bug.
  defp contained(build) do
    build.()
  catch
    kind, reason ->
      {:error,
       %ProposalProductionError{
         stage: :internal,
         reason: Exception.format_banner(kind, reason, __STACKTRACE__) <> origin(__STACKTRACE__)
       }}
  end

  defp origin([entry | _]), do: " at " <> Exception.format_stacktrace_entry(entry)
  defp origin([]), do: ""

  # The observations now belong to the proposal they led to, and their
  # intents say so, like every other intent in it.
  defp attach(observations, %Proposal{id: proposal_id}) do
    Enum.map(observations, fn observation ->
      %{observation | intent: %{observation.intent | proposal_id: proposal_id}}
    end)
  end

  ## --- Client call, with a bound this module owns end to end -----------

  # The same timeout is handed to the client (so it can bound its own
  # I/O) and used here as a backstop against clients that ignore it.
  # Whichever fires first, the result is {:error, :timeout}, so the
  # outcome is stage: :timeout either way.
  defp call_with_timeout(client, messages, timeout_ms, model) do
    task = Task.async(fn -> safe_complete(client, messages, timeout_ms, model) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Task.async/1 re-raises inside the caller on Task.yield/2 if the
  # task's function raised -- catching here, inside the task itself,
  # keeps a misbehaving client from ever propagating as an exception at
  # all, rather than relying on a caller-side rescue.
  #
  defp safe_complete(client, messages, timeout_ms, model_string) do
    model_id = String.split(model_string, ":", parts: 2) |> :lists.last()
    client.complete(messages, timeout_ms, model_id)
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp add_usage(cumulative, nil), do: cumulative
  defp add_usage(nil, usage), do: usage

  defp add_usage(left, right) do
    %{
      input_tokens: left.input_tokens + right.input_tokens,
      output_tokens: left.output_tokens + right.output_tokens,
      total_tokens: left.total_tokens + right.total_tokens
    }
    |> add_optional_usage(left, right, :cache_creation_input_tokens)
    |> add_optional_usage(left, right, :cache_read_input_tokens)
  end

  defp add_optional_usage(cumulative, left, right, key) do
    if Map.has_key?(left, key) or Map.has_key?(right, key) do
      Map.put(cumulative, key, Map.get(left, key, 0) + Map.get(right, key, 0))
    else
      cumulative
    end
  end
end
