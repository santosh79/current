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
  under the runtime's file-access rules. The model is then asked again
  with everything it has been shown so far. Nothing is kept between
  calls but that list, so every prompt is rebuilt from the same inputs.

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
    * the whole build -- every call and every read -- by
      `task_timeout_ms/0`.

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
    Observer
  }

  alias Current.Error.ProposalProductionError

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
  @spec build(Request.t(), Current.Id.t(), module(), pos_integer(), Path.t() | nil) ::
          {:ok, Proposal.t()}
          | {:ok, Proposal.t(), Current.Id.t()}
          | {:error, ProposalProductionError.t()}
  def build(%Request{model: model} = req, workflow_id, client, timeout_ms, project_dir)
      when is_binary(model) and is_integer(timeout_ms) and timeout_ms > 0 do
    within_task_timeout(fn ->
      with {:ok, project} <- project_layout(project_dir) do
        converse(%{
          request: req,
          workflow_id: workflow_id,
          client: client,
          call_timeout_ms: timeout_ms,
          project: project,
          observations: [],
          shown: [],
          rounds_left: @max_observe_rounds,
          budget: @context_budget_bytes
        })
      end
    end)
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
  defp within_task_timeout(build) do
    timeout_ms = task_timeout_ms()
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
    prompt = prompt_for(state)

    case call_with_timeout(state.client, prompt, state.call_timeout_ms, state.request.model) do
      {:ok, raw} ->
        handle_reply(raw, state)

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
            shown: state.shown ++ texts,
            rounds_left: state.rounds_left - 1,
            budget: budget
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
  defp call_with_timeout(client, prompt, timeout_ms, model) do
    task = Task.async(fn -> safe_complete(client, prompt, timeout_ms, model) end)

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
  defp safe_complete(client, prompt, timeout_ms, model) do
    case split(model) do
      {:ok, _provider, model_id} ->
        {:ok, pid} = client.start_link([])
        response = client.complete(pid, prompt, timeout_ms, model_id)
        response

      :error ->
        {:error, {:invalid_model, model}}
    end
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  ## --- Prompt -----------------------------------------------------------

  # Everything that is the same for every turn of every task on this
  # project comes first, and the observations are only ever appended to,
  # so a provider's prompt cache can reuse the longest possible prefix.
  defp prompt_for(%{request: %Request{input: input, context: context}} = state) do
    """
    You are Current, an agent that proposes structured changes to a codebase.

    On every turn you reply with exactly ONE JSON object -- no prose, no
    markdown fences. There are two kinds of reply:

    1. CONTEXT REQUEST -- {"observe": [...]}. Use it when you need to look
       at the project before you can propose the complete work. The runtime
       shows you what you asked for and asks you again.

    2. PROPOSAL -- {"intents": [...], ...}. Use it only when you have seen
       what you need. It ends the exchange.

    Never mix the two in one reply. Do not put read_file, glob or grep in a
    proposal to find something out that you need in order to write that
    proposal: that is what a context request is for.

      - read_file / glob / grep inside "observe" mean: "show me this, so I
        can decide what to propose".
      - read_file / glob / grep inside a proposal mean: "reading this is
        itself part of the proposed work" -- for example the evidence a
        claim cites.

    Both replies are described by the schema below (definitions.context_request
    and definitions.proposal).

    #{Current.ProposalWireSchema.raw()}

    #{file_patch_rules()}

    #{observe_rules()}

    Project layout (paths are relative to the project root; contents are not shown):

    #{render_layout(state.project)}

    Request: #{inspect(input)}
    Context: #{inspect(context)}

    #{render_shown(state.shown)}

    #{render_turn(state.rounds_left)}
    """
  end

  defp observe_rules do
    """
    Seeing the project:

    You are shown the project's layout, not its files. To see more, reply
    with a context request instead of a proposal -- a JSON object with the
    single key "observe" (definitions.context_request in the schema above):

    {"observe": [
      {"reason": "see how greetings are built",
       "intent": {"type": "read_file", "path": "lib/greeter.ex"}},
      {"reason": "find the other modules",
       "intent": {"type": "glob", "pattern": "lib/**/*.ex"}},
      {"reason": "find every caller of hello",
       "intent": {"type": "grep", "pattern": "hello(", "paths": ["lib/greeter.ex", "lib/app.ex"]}}
    ]}

    - Each entry is an observation (definitions.observation): one "intent"
      and a short "reason" saying why you need to see it. The reason is
      kept on record with your proposal.
    - The intent must be a read_file, glob or grep, with the same fields
      it has in a proposal. Paths are relative to the project root. grep
      matches a literal string line by line, in the files listed; it does
      not take directories.
    - The runtime runs them and asks you again with the results added
      below. Nothing else happens: a context request changes nothing.
    - Ask for everything you expect to need at once. The number of context
      requests and the amount of text you can be shown are both limited.
    - Only patch or rely on files whose contents you have been shown.
      Their contents appear below as <file path="...">...</file>.
    """
  end

  defp render_layout(%{files: [], omitted: 0}), do: "(the project has no files)"

  defp render_layout(%{files: files, omitted: omitted}) do
    listed = Enum.map(files, fn %{path: path, bytes: bytes} -> "#{path} (#{bytes} bytes)" end)

    more =
      if omitted > 0,
        do: ["... and #{omitted} more files not listed; use glob to find them"],
        else: []

    Enum.join(listed ++ more, "\n")
  end

  defp render_shown([]), do: "You have not been shown any file contents yet."

  defp render_shown(texts) do
    "What you have been shown so far, in the order you asked:\n\n" <> Enum.join(texts, "\n\n")
  end

  defp render_turn(0) do
    "You have no context requests left. Reply with the proposal now."
  end

  defp render_turn(rounds_left) do
    "You may make #{rounds_left} more context request(s). " <>
      "Reply with a context request, or with the proposal if you have what you need."
  end

  ## --- file_patch diff format ---------------------------------------------

  # Current.EffectApplicator applies a file_patch by running exactly
  # `patch --batch --forward --fuzz=0 <path> <diff>`, so the diff has to
  # be a unified diff that POSIX patch accepts as is. Models otherwise
  # tend to fall back on their own patch formats (e.g. "*** Begin
  # Patch"), which patch rejects.

  @example_before """
  defmodule Greeter do
    def hello(name) do
      "Hello, " <> name
    end
  end
  """

  @example_diff """
  --- a/lib/greeter.ex
  +++ b/lib/greeter.ex
  @@ -1,5 +1,9 @@
   defmodule Greeter do
     def hello(name) do
       "Hello, " <> name
     end
  +
  +  def goodbye(name) do
  +    "Goodbye, " <> name
  +  end
   end
  """

  @example_after """
  defmodule Greeter do
    def hello(name) do
      "Hello, " <> name
    end

    def goodbye(name) do
      "Goodbye, " <> name
    end
  end
  """

  @doc false
  # The example in the prompt, with the file before and after, so a test
  # can check the example itself applies with patch.
  def file_patch_example, do: {@example_before, @example_diff, @example_after}

  defp file_patch_rules do
    """
    Rules for file_patch intents:

    - "diff" must be a standard unified diff of that one file -- the format
      `diff -u` produces. It is applied with exactly:
        patch --batch --forward --fuzz=0 <path> <diff>
      Any other patch format is rejected. In particular do NOT use the
      "*** Begin Patch" / "*** Update File" format, and do not write "@@"
      lines without line numbers.
    - Start with "--- a/<path>" and "+++ b/<path>", then one or more hunks.
    - Each hunk starts with "@@ -<old_start>,<old_count> +<new_start>,<new_count> @@".
      old_start and new_start are the 1-based line numbers where the hunk
      begins in the file before and after the change. old_count is the
      number of context and removed lines in the hunk; new_count is the
      number of context and added lines. All four must be correct.
    - Every line inside a hunk starts with exactly one character: " " for
      context, "-" for a removed line, "+" for an added line. A blank
      context line is a single space.
    - Context and removed lines must match the file as it was shown to
      you, character for character, whitespace included. Give up to 3
      lines of context around each change.
    - The file must already exist. To create a new file, use write_file.
      write_file only ever creates files -- it fails if the file already
      exists -- so never use it to rewrite an existing file; change an
      existing file with file_patch (several hunks are fine).

    Example. For lib/greeter.ex containing

    <file path="lib/greeter.ex">
    #{String.trim_trailing(@example_before)}
    </file>

    a file_patch adding a goodbye/1 function has this "diff" (the tags are
    not part of it):

    <diff>
    #{String.trim_trailing(@example_diff)}
    </diff>
    """
  end

  def split(model_name) when is_binary(model_name) do
    case String.split(model_name, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {:ok, provider, model_id}

      _ ->
        :error
    end
  end
end
