defmodule Current.LLMProposalBuilder do
  @moduledoc """
  Wires the LLM boundary together: Current.LLMClient (talks to the
  model, owns nothing about Current's vocabulary) -> BlobStore (raw
  response preserved for provenance, always, success or failure) ->
  Current.ProposalDecoder (untrusted bytes -> typed Proposal.t()).

  Per Current.ProposalBuilder's @callback contract, this module owns its
  own crash and timeout handling completely -- WorkflowOrchestrator no
  longer enforces either (see start_proposal_production/1). A client
  call that hangs, raises, or returns garbage must never escape this
  module as anything other than {:ok, ...} or
  {:error, %Current.Error.ProposalProductionError{}}.
  """

  @behaviour Current.ProposalBuilder

  alias Current.{BlobStore, ProjectContext, Proposal, ProposalDecoder, Request}
  alias Current.Error.ProposalProductionError

  @impl true
  @spec build(Request.t(), Current.Id.t(), module(), pos_integer(), Path.t() | nil) ::
          {:ok, Proposal.t()}
          | {:ok, Proposal.t(), Current.Id.t()}
          | {:error, ProposalProductionError.t()}
  def build(%Request{} = req, workflow_id, client, timeout_ms, project_dir)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, project} <- project_context(project_dir) do
      req
      |> prompt_for(project)
      |> request_proposal(workflow_id, client, timeout_ms)
    end
  end

  defp project_context(nil) do
    {:error, %ProposalProductionError{stage: :project_context, reason: :no_project_dir}}
  end

  defp project_context(project_dir) do
    case ProjectContext.build(project_dir) do
      {:ok, project} ->
        {:ok, project}

      {:error, reason} ->
        {:error, %ProposalProductionError{stage: :project_context, reason: reason}}
    end
  end

  defp request_proposal(prompt, workflow_id, client, timeout_ms) do
    case call_with_timeout(client, prompt, timeout_ms) do
      {:ok, raw} ->
        decode(raw, workflow_id)

      {:error, :timeout} ->
        {:error,
         %ProposalProductionError{
           stage: :timeout,
           reason: "no response after #{timeout_ms}ms"
         }}

      {:error, reason} ->
        {:error,
         %ProposalProductionError{
           stage: :connection,
           reason: reason
         }}
    end
  end

  ## --- Client call, with a bound this module owns end to end -----------

  # The same timeout is handed to the client (so it can bound its own
  # I/O) and used here as a backstop against clients that ignore it.
  # Whichever fires first, the result is {:error, :timeout}, so the
  # outcome is stage: :timeout either way.
  defp call_with_timeout(client, prompt, timeout_ms) do
    task = Task.async(fn -> safe_complete(client, prompt, timeout_ms) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Task.async/1 re-raises inside the caller on Task.yield/2 if the
  # task's function raised -- catching here, inside the task itself,
  # keeps a misbehaving client from ever propagating as an exception at
  # all, rather than relying on a caller-side rescue.
  defp safe_complete(client, prompt, timeout_ms) do
    client.complete(prompt, timeout_ms)
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  ## --- Decode + provenance ------------------------------------------------

  defp decode(raw, workflow_id) do
    {:ok, raw_output_blob_id} = BlobStore.put(raw)

    case ProposalDecoder.decode(raw, workflow_id) do
      {:ok, %Proposal{} = proposal} ->
        {:ok, proposal, raw_output_blob_id}

      {:error, reason} ->
        {:error,
         %ProposalProductionError{
           stage: :decode,
           reason: reason,
           raw_output_blob_id: raw_output_blob_id
         }}
    end
  end

  ## --- Prompt -----------------------------------------------------------

  defp prompt_for(%Request{input: input, context: context}, project) do
    """
    You are Current, an agent that proposes structured changes to a codebase.

    Request: #{inspect(input)}
    Context: #{inspect(context)}

    Project files (paths are relative to the project root):

    #{render_files(project.files)}

    Respond with a single JSON object matching the schema described below.
    Return nothing but that JSON object -- no prose, no markdown fences.

    #{Current.ProposalWireSchema.raw()}

    #{file_patch_rules()}
    """
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
    - Context and removed lines must match the file shown above character
      for character, whitespace included. Give up to 3 lines of context
      around each change.
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

  defp render_files(files) do
    files
    |> Enum.sort_by(fn {path, _contents} -> path end)
    |> Enum.map_join("\n", fn {path, contents} ->
      "=== #{path} ===\n#{contents}"
    end)
  end
end
