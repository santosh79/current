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
    Observer
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
  @spec build(Request.t(), Current.Id.t(), module(), pos_integer(), Path.t() | nil) ::
          {:ok, Proposal.t()}
          | {:ok, Proposal.t(), Current.Id.t()}
          | {:error, ProposalProductionError.t()}
  def build(%Request{model: model} = req, workflow_id, client, timeout_ms, project_dir)
      when is_binary(model) and is_integer(timeout_ms) and timeout_ms > 0 do
    within_task_timeout(req, task_timeout_ms(), fn ->
      with {:ok, project} <- project_layout(project_dir) do
        converse(%{
          request: req,
          workflow_id: workflow_id,
          client: client,
          call_timeout_ms: timeout_ms,
          project: project,
          messages: initial_messages(req, project, project_dir),
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
  defp within_task_timeout(%Request{timeout_ms: requested}, default_timeout_ms, build) do
    timeout_ms = requested || default_timeout_ms
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
           state.request.model
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
          | messages: append_message(state.messages, :assistant, raw),
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
              append_message(
                state.messages,
                :user,
                observation_message(texts, state.rounds_left - 1)
              ),
            rounds_left: state.rounds_left - 1,
            repairs_left: @max_repairs,
            budget: budget
        })

      {:error, reason} when state.repairs_left > 0 ->
        converse(%{
          state
          | messages: append_message(state.messages, :user, repair_message(reason)),
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
  defp safe_complete(client, messages, timeout_ms, model) do
    case split(model) do
      {:ok, _provider, model_id} ->
        client.complete(messages, timeout_ms, model_id)

      :error ->
        {:error, {:invalid_model, model}}
    end
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  ## --- Messages ---------------------------------------------------------

  # The protocol is stable system context. The task-specific layout and
  # request are the first user turn; every later turn is appended so the
  # provider can reuse the byte-identical conversation prefix.
  defp initial_messages(%Request{input: input, context: context} = req, project, project_dir) do
    system =
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

      #{run_command_rules()}

      #{edit_file_rules()}

      #{observe_rules()}
      """

    user =
      """
      Project layout (paths are relative to the project root; contents are not shown):

      #{render_layout(project)}

      Request: #{inspect(input)}
      Context: #{inspect(context)}
      #{render_revision(req.revision, project_dir)}
      You have not been shown any file contents yet. Before your next reply, plan
      which files the change depends on: if you need to look at the project, ask
      for the relevant files together in one context request rather than one at a
      time, since the conversation is re-sent with every round.

      #{render_turn(@max_observe_rounds)}
      """

    [%{role: :system, content: system}, %{role: :user, content: user}]
  end

  ## --- Revisions ---------------------------------------------------------

  # Each artifact a prior proposal shows is cut to this many characters.
  @revision_artifact_chars 2_000

  @doc """
  The part of the first user turn that appears only when a reviewer sent
  an earlier proposal back (`request.revision`): every proposal so far,
  every round of feedback, what the agent looked at before, and the
  instruction to answer with a complete replacement. Empty for a first
  proposal. The conversation starts fresh: nothing from the earlier
  exchange is carried over except what is rendered here, so the agent can
  observe again as needed.
  """
  @spec render_revision(Request.revision() | nil, Path.t() | nil) :: String.t()
  def render_revision(nil, _project_dir), do: ""

  def render_revision(%{previous: previous, feedback: feedback}, project_dir) do
    last_index = length(previous) - 1

    proposals =
      previous
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {proposal, index} ->
        render_prior(proposal, index + 1, index == last_index, project_dir)
      end)

    rounds =
      feedback
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {text, round} ->
        "Feedback on proposal #{round}: #{inspect(text)}"
      end)

    looked_at =
      case previous |> Enum.flat_map(&observed/1) |> Enum.uniq() do
        [] ->
          ""

        paths ->
          "\nWhat you looked at before (it may help; look again if you need to):\n" <>
            Enum.map_join(paths, "\n", &"  - #{&1}") <> "\n"
      end

    """

    A reviewer has asked for changes to your earlier proposal#{if length(previous) == 1, do: "", else: "s"}.

    #{proposals}

    #{rounds}
    #{looked_at}
    Reply with a complete replacement proposal that addresses the latest feedback.
    It replaces the earlier ones entirely, so keep whatever the reviewer did not
    object to.
    """
  end

  defp render_prior(proposal, number, latest?, project_dir) do
    [
      "Proposal #{number}#{if latest?, do: " (the latest)", else: ""}:",
      if(present?(proposal.justification), do: "  Justification: #{proposal.justification}"),
      case proposal.claims do
        [_ | _] = claims -> "  Claims:\n" <> Enum.map_join(claims, "\n", &"    - #{&1}")
        _ -> nil
      end,
      "  Intents:",
      proposal.intents
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {intent, n} ->
        "    #{n}. " <> render_intent(intent, project_dir, latest?)
      end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Only the latest proposal shows its text; older ones are one line per
  # intent, so the prompt stays bounded however many revisions there were.
  defp render_intent(%Current.Intent.EditFile{} = edit, root, true) do
    "edit_file #{rel(edit.path, root)}\n" <>
      "       replace:\n#{artifact_text(edit.old_artifact_id)}\n" <>
      "       with:\n#{artifact_text(edit.new_artifact_id)}"
  end

  defp render_intent(%Current.Intent.WriteFile{} = write, root, true) do
    "write_file #{rel(write.path, root)}\n#{artifact_text(write.contents_artifact_id)}"
  end

  defp render_intent(%Current.Intent.EditFile{path: path}, root, false),
    do: "edit_file #{rel(path, root)}"

  defp render_intent(%Current.Intent.WriteFile{path: path}, root, false),
    do: "write_file #{rel(path, root)}"

  defp render_intent(%Current.Intent.ReadFile{path: path}, root, _),
    do: "read_file #{rel(path, root)}"

  defp render_intent(%Current.Intent.DeleteFile{path: path}, root, _),
    do: "delete_file #{rel(path, root)}"

  defp render_intent(%Current.Intent.RunCommand{cmd: cmd, args: args}, _root, _),
    do: "run_command #{Enum.join([cmd | args || []], " ")}"

  defp render_intent(%Current.Intent.Grep{pattern: pattern}, _root, _),
    do: "grep #{inspect(pattern)}"

  defp render_intent(%Current.Intent.Glob{pattern: pattern}, _root, _),
    do: "glob #{inspect(pattern)}"

  defp render_intent(%Current.Intent.Claim{statement: statement}, _root, _),
    do: "claim #{inspect(statement)}"

  defp render_intent(%Current.Intent.Report{summary: summary}, _root, _),
    do: "report #{inspect(summary)}"

  defp render_intent(other, _root, _), do: inspect(other.__struct__)

  defp artifact_text(artifact_id) do
    text =
      case BlobStore.read(artifact_id) do
        {:ok, bytes} when is_binary(bytes) ->
          if String.valid?(bytes),
            do: truncate_chars(bytes, @revision_artifact_chars),
            else: "(binary content)"

        {:error, _reason} ->
          "(content unavailable)"
      end

    text |> String.split("\n") |> Enum.map_join("\n", &("         | " <> &1))
  end

  defp truncate_chars(text, max) do
    if String.length(text) > max,
      do: String.slice(text, 0, max) <> "\n… (cut)",
      else: text
  end

  # What the agent asked to see, from the observations kept with each
  # proposal; refused requests are left out.
  defp observed(%Proposal{observations: observations}) do
    for %Current.Observation{status: :shown, intent: intent} <- observations || [],
        label = observation_label(intent),
        label != nil,
        do: label
  end

  defp observation_label(%Current.Intent.ReadFile{path: path}), do: "read_file #{path}"
  defp observation_label(%Current.Intent.Glob{pattern: pattern}), do: "glob #{pattern}"
  defp observation_label(%Current.Intent.Grep{pattern: pattern}), do: "grep #{inspect(pattern)}"
  defp observation_label(_other), do: nil

  # Persisted paths are absolute; the model works in project-relative ones.
  defp rel(path, root) when is_binary(path) and is_binary(root), do: Path.relative_to(path, root)
  defp rel(path, _root), do: to_string(path)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp append_message(messages, role, content) do
    messages ++ [%{role: role, content: content}]
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

  defp observation_message(texts, rounds_left) do
    """
    What you have been shown for your latest context request, in the order you asked:

    #{Enum.join(texts, "\n\n")}

    #{render_turn(rounds_left)}
    """
  end

  defp repair_message(reason) do
    "Your previous reply could not be used (#{reason}). Reply again with exactly " <>
      "ONE bare JSON object: either {\"observe\": [...]} or {\"intents\": [...]}. " <>
      "No tags, no markdown fences, no prose."
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
    - Be deliberate about context. Each context request is another model call
      that re-sends the whole conversation so far, including every file already
      shown, so the transcript grows with every round. (Provider prompt caching
      may reduce what is actually billed, but the transcript still grows.) Plan
      before you ask, and batch the context you can already tell is relevant
      into one request. Aim to gather sufficient context in as few rounds as
      practical; use additional rounds when correctness requires them.
    - When you plan a request, think through what the change touches: the
      files you will edit; the files that directly call or are called by them;
      related tests; and config, types, schemas or docs the change must stay
      consistent with. Include these together rather than discovering them one
      round at a time.
    - Use grep when the change alters an interface, renames something, or may
      affect references you cannot see from the files already requested; list
      the files where such references could appear. Do not grep for names the
      change will not affect.
    - Prefer read_file on paths you can already see in the layout over a glob
      followed by reads. Use glob for files the layout does not list. Avoid
      speculative reads of large files that are unlikely to matter; ask for
      them in a later round only if the results show you need them.
    - Ask again for what the results show you could not have known to ask for
      (for example a file a result revealed), and never re-request something
      you have already been shown. Do not stop investigating before you have
      what you need to propose correct work.
    - The number of context requests and the amount of text you can be shown
      are both limited.
    - Only edit or rely on files whose contents you have been shown.
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

  defp render_turn(0) do
    "You have no context requests left. Reply with the proposal now."
  end

  defp render_turn(rounds_left) do
    "You may make #{rounds_left} more context request(s). " <>
      "Reply with a context request, or with the proposal if you have what you need. " <>
      "If you do ask again, ask for everything still missing in that one reply, " <>
      "since the conversation is re-sent with every round."
  end

  ## --- run_command rules ----------------------------------------------------

  defp run_command_rules do
    case Application.get_env(:current, :allowed_commands, []) do
      [] ->
        """
        RunCommand policy:

        No commands are allowed by this runtime.
        Do not propose run_command intents; they would be refused when the proposal is applied.
        """

      allowed_commands ->
        """
        RunCommand policy:

        The allowed `cmd` values are exactly: #{JSON.encode!(allowed_commands)}.
        Only propose a run_command intent whose `cmd` exactly matches one of
        those strings. Any other command will be refused when the proposal is
        applied. This executable allowlist is not a sandbox.
        It does not restrict command arguments.
        """
    end
  end

  ## --- edit_file rules ------------------------------------------------------

  # A file is changed by naming the exact text to replace, not by writing
  # a unified diff: models miscount hunk headers, and `patch --fuzz=0`
  # rejects any miscount. Current.Edit does the replacing.

  @example_before """
  defmodule Greeter do
    def hello(name) do
      "Hello, " <> name
    end
  end
  """

  @example_old """
      "Hello, " <> name
    end
  """

  @example_new """
      "Hello, " <> name
    end

    def goodbye(name) do
      "Goodbye, " <> name
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
  # The example in the prompt: a file before, the edit's two strings, and
  # the file after, so a test can check the example itself applies.
  def edit_file_example, do: {@example_before, @example_old, @example_new, @example_after}

  defp edit_file_rules do
    """
    Rules for edit_file intents:

    - edit_file changes an existing file by replacing the text "old_string"
      with "new_string".
    - "old_string" must occur in the file EXACTLY ONCE, character for
      character, whitespace and indentation included. Copy it from the
      file contents you were shown; do not retype it from memory and do
      not include line numbers.
    - If the text you want to change occurs more than once, add enough
      surrounding lines to "old_string" to make it unique. Set
      "replace_all": true only to replace every occurrence on purpose, for
      example to rename an identifier.
    - Keep "old_string" as small as still unique -- the lines being changed
      and a line or two around them -- not the whole file. Make a separate
      edit_file for each separate change.
    - Several edit_file intents on one file are applied in order, so each
      one must match the file as the earlier ones leave it.
    - "new_string" may be empty, which deletes "old_string". "old_string"
      must not be empty and must differ from "new_string".
    - The file must already exist. To create a new file, use write_file.
      write_file only ever creates files -- it fails if the file already
      exists -- so never use it to rewrite an existing file; change an
      existing file with edit_file.

    Example. For lib/greeter.ex containing

    <file path="lib/greeter.ex">
    #{String.trim_trailing(@example_before)}
    </file>

    this intent adds a goodbye/1 function:

    {"type": "edit_file", "path": "lib/greeter.ex",
     "old_string": #{JSON.encode!(@example_old)},
     "new_string": #{JSON.encode!(@example_new)}}
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
