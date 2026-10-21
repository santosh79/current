defmodule Current.IntentValidator do
  @moduledoc """
  Validates a decoded Proposal's intents before they become durable.

  This is deliberately narrower than "will this succeed when applied":
  validation protects the contract (referenced blobs exist, structural
  shape is sane, claims only cite earlier intents whose condition they
  could ever evaluate), not the world's future state. Whether a command's
  executable happens to be on this box's PATH can change between
  validation and apply -- that stays an effect-time-only failure (see
  EffectApplicator), exactly as it already was.

  ## File state across intents

  EffectApplicator applies intents in order, so each one sees the files as
  the earlier ones left them. Validation mirrors that with an in-memory
  overlay, `files`, of what the *proposal itself* has done to each path so
  far:

    * `{:present, contents}` -- an earlier `write_file` or `edit_file`
      left the file with these contents;
    * `:absent` -- an earlier `delete_file` removed it;
    * no entry -- nothing in the proposal has touched the path yet, so the
      file on disk is the truth.

  Nothing is written to disk. The overlay is only as good as its model:
  a `run_command` can change files in ways validation cannot predict
  (a formatter, a code generator), so intents after one are checked
  against what the proposal's own file intents imply, not what the command
  did.

  Every member of Current.Intent.t() must have an explicit clause below.
  There is no catch-all: an intent type with no clause is a compile-time
  gap this module should never silently accept.

  Before any per-intent rule runs, every path field must be absolute and
  inside `project_dir` (see Current.IntentPaths). WorkflowOrchestrator
  absolutizes proposals before they get here, so a relative path at this
  point means the caller skipped that step, and is rejected rather than
  resolved against this node's working directory.
  """

  alias Current.{BlobStore, Intent, IntentPaths, Proposal}
  alias Current.Error.ValidationError

  @type files :: %{optional(Path.t()) => {:present, binary()} | :absent}
  @type state :: %{seen: %{optional(Current.Id.t()) => Intent.t()}, files: files()}

  @spec validate(Proposal.t(), Path.t()) :: :ok | {:error, ValidationError.t()}
  def validate(%Proposal{intents: intents}, project_dir) when is_binary(project_dir) do
    validate_helper(intents, %{seen: %{}, files: %{}}, Path.expand(project_dir))
  end

  ## --- File overlay ---------------------------------------------------------

  # The file's contents as the proposal has left it so far.
  defp read_current(path, files) do
    case Map.fetch(files, path) do
      {:ok, {:present, contents}} -> {:ok, contents}
      {:ok, :absent} -> :error
      :error -> File.read(path) |> normalize_read()
    end
  end

  defp normalize_read({:ok, contents}), do: {:ok, contents}
  defp normalize_read({:error, _reason}), do: :error

  # Whether a regular file exists at `path` as the proposal has left it.
  defp exists_current?(path, files) do
    case Map.fetch(files, path) do
      {:ok, {:present, _contents}} -> true
      {:ok, :absent} -> false
      :error -> File.regular?(path)
    end
  end

  ## --- Paths (every intent) ---------------------------------------------

  defp validate_paths(intent, project_dir) do
    case IntentPaths.violation(intent, project_dir) do
      nil ->
        nil

      {field, path, problem} ->
        %ValidationError{
          intent_id: intent.id,
          reason: path_reason(field, problem),
          details: %{field: field, path: path, project_dir: project_dir}
        }
    end
  end

  defp path_reason(field, :not_absolute), do: "#{field} must be an absolute path"
  defp path_reason(field, :outside_project_dir), do: "#{field} is outside the project directory"
  defp path_reason(field, :parent_segment), do: "#{field} must not contain '..'"

  ## --- Per-intent rules -----------------------------------------------------
  # Each clause returns {:ok, files} -- the overlay after this intent -- or a
  # ValidationError.

  ## --- ReadFile -------------------------------------------------------

  defp validate_intent(%Intent.ReadFile{id: id, path: path}, %{files: files}) do
    case exists_current?(path, files) do
      true ->
        {:ok, files}

      _ ->
        %ValidationError{
          intent_id: id,
          reason: "read_file path does not exist",
          details: %{path: path}
        }
    end
  end

  ## --- WriteFile --------------------------------------------------------
  # Whether `path` already exists *on disk* is apply-time only
  # (EffectApplicator already handles it) -- it can change between now and
  # apply. A file the proposal itself created or edited earlier is a
  # different matter: that is deterministic, so it is rejected here.

  defp validate_intent(
         %Intent.WriteFile{id: id, path: path, contents_artifact_id: blob_id},
         %{files: files}
       ) do
    case BlobStore.read(blob_id) do
      {:ok, contents} ->
        case Map.get(files, path) do
          {:present, _} ->
            %ValidationError{
              intent_id: id,
              reason: "write_file path already exists earlier in this proposal",
              details: %{path: path}
            }

          _ ->
            {:ok, Map.put(files, path, {:present, contents})}
        end

      {:error, _reason} ->
        %ValidationError{
          intent_id: id,
          reason: "write_file contents blob does not exist",
          details: %{contents_artifact_id: blob_id}
        }
    end
  end

  ## --- DeleteFile -------------------------------------------------------
  # No existence check: EffectApplicator already treats a missing target
  # as "already deleted" rather than an error, so there's nothing here
  # for validation to usefully reject ahead of time.

  defp validate_intent(%Intent.DeleteFile{id: id, path: path}, %{files: files}) do
    case is_binary(path) and path != "" do
      true ->
        {:ok, Map.put(files, path, :absent)}

      _ ->
        %ValidationError{
          intent_id: id,
          reason: "delete_file path must be a non-empty string",
          details: %{path: path}
        }
    end
  end

  ## --- EditFile -----------------------------------------------------------
  # The edit is checked against the file as the proposal has left it
  # (see "File state across intents"), so a human is never asked to approve
  # an edit that cannot apply, and a second edit can rely on the first.
  # EffectApplicator checks again at apply time, because the file on disk
  # can change in between.

  defp validate_intent(
         %Intent.EditFile{
           id: id,
           path: path,
           old_artifact_id: old_id,
           new_artifact_id: new_id,
           replace_all: replace_all
         },
         %{files: files}
       ) do
    with {:file, {:ok, contents}} <- {:file, read_current(path, files)},
         {:old, {:ok, old}} <- {:old, BlobStore.read(old_id)},
         {:new, {:ok, new}} <- {:new, BlobStore.read(new_id)},
         {:edit, {:ok, edited, _count}} <-
           {:edit, Current.Edit.replace(contents, old, new, replace_all)} do
      {:ok, Map.put(files, path, {:present, edited})}
    else
      {:file, _} ->
        %ValidationError{
          intent_id: id,
          reason: "edit_file path does not exist",
          details: %{path: path}
        }

      {:old, _} ->
        %ValidationError{
          intent_id: id,
          reason: "edit_file old_string blob does not exist",
          details: %{old_artifact_id: old_id}
        }

      {:new, _} ->
        %ValidationError{
          intent_id: id,
          reason: "edit_file new_string blob does not exist",
          details: %{new_artifact_id: new_id}
        }

      {:edit, {:error, message}} ->
        %ValidationError{
          intent_id: id,
          reason: "edit_file #{message}",
          details: %{path: path}
        }
    end
  end

  ## --- RunCommand -------------------------------------------------------
  # Deliberately no System.find_executable/1 check: what's on PATH here,
  # at validation time, may not be what's on PATH wherever/whenever this
  # gets applied. "command not found" stays an EffectApplicator failure.
  # The overlay is left as is: what a command does to files is unknowable.

  defp validate_intent(%Intent.RunCommand{id: id, cmd: cmd, args: args}, %{files: files}) do
    cond do
      not (is_binary(cmd) and cmd != "") ->
        %ValidationError{
          intent_id: id,
          reason: "run_command cmd must be a non-empty string",
          details: %{cmd: cmd}
        }

      not (is_list(args) and Enum.all?(args, &is_binary/1)) ->
        %ValidationError{
          intent_id: id,
          reason: "run_command args must be a list of strings",
          details: %{args: args}
        }

      true ->
        {:ok, files}
    end
  end

  ## --- Grep -------------------------------------------------------------

  defp validate_intent(%Intent.Grep{id: id, paths: paths}, %{files: files}) do
    case Enum.find(paths, &(not exists_current?(&1, files))) do
      nil ->
        {:ok, files}

      path ->
        %ValidationError{
          intent_id: id,
          reason: "grep path does not exist",
          details: %{path: path}
        }
    end
  end

  ## --- Glob -------------------------------------------------------------
  # Directories are not tracked in the overlay, so base_dir is checked on
  # disk.

  defp validate_intent(
         %Intent.Glob{id: id, pattern: pattern, base_dir: base_dir},
         %{files: files}
       ) do
    cond do
      not is_binary(pattern) or Path.type(pattern) == :absolute ->
        %ValidationError{
          intent_id: id,
          reason: "glob pattern must be a relative path",
          details: %{pattern: pattern}
        }

      not File.dir?(base_dir) ->
        %ValidationError{
          intent_id: id,
          reason: "glob base_dir does not exist",
          details: %{base_dir: base_dir}
        }

      true ->
        {:ok, files}
    end
  end

  ## --- Claim --------------------------------------------------------------
  # Structural only: does the evidence shape make sense, does it point at
  # an intent that already ran (by proposal order), and could this
  # condition ever be evaluated against *that kind* of intent at all?
  # Whether the *result* actually satisfies the condition is
  # EffectApplicator's job at apply time -- this is "can this claim in
  # principle be evaluated," not "will it pass."

  defp validate_intent(%Intent.Claim{id: id, evidence: nil}, _state) do
    %ValidationError{
      intent_id: id,
      reason: "claim requires evidence",
      details: %{}
    }
  end

  defp validate_intent(%Intent.Claim{id: id, evidence: evidence}, %{seen: seen, files: files}) do
    source_intent_id = evidence_field(evidence, :source_intent_id)
    condition = evidence_field(evidence, :condition)

    cond do
      is_nil(source_intent_id) ->
        %ValidationError{
          intent_id: id,
          reason: "claim evidence missing source_intent_id",
          details: %{evidence: evidence}
        }

      not Map.has_key?(seen, source_intent_id) ->
        %ValidationError{
          intent_id: id,
          reason: "claim references an intent that does not precede it in the proposal",
          details: %{source_intent_id: source_intent_id}
        }

      not condition_compatible?(condition, Map.fetch!(seen, source_intent_id)) ->
        source_intent = Map.fetch!(seen, source_intent_id)

        %ValidationError{
          intent_id: id,
          reason:
            "claim condition #{inspect(condition)} can never be evaluated against " <>
              "#{inspect(source_intent.__struct__)}",
          details: %{condition: condition, source_intent_id: source_intent_id}
        }

      true ->
        {:ok, files}
    end
  end

  ## --- Report -------------------------------------------------------------

  defp validate_intent(%Intent.Report{}, %{files: files}), do: {:ok, files}

  ## --- Driver ---------------------------------------------------------------

  defp validate_helper([], _state, _project_dir) do
    :ok
  end

  defp validate_helper([intent | rest], state, project_dir) do
    with nil <- validate_paths(intent, project_dir),
         {:ok, files} <- validate_intent(intent, state) do
      state = %{state | seen: Map.put(state.seen, intent.id, intent), files: files}
      validate_helper(rest, state, project_dir)
    else
      %ValidationError{} = error -> {:error, error}
    end
  end

  defp evidence_field(evidence, key) when is_map(evidence), do: Map.get(evidence, key)
  defp evidence_field(_evidence, _key), do: nil

  # Mirrors exactly the (condition, result-type) pairs EffectApplicator's
  # evaluate_condition/5 supports. If a pair is added there, it must be
  # added here too, or a technically-valid claim will always fail at
  # apply time with "condition not supported" instead of being caught here.
  defp condition_compatible?(:match_count_greater_than, %Intent.Grep{}), do: true
  defp condition_compatible?(:match_count_greater_than, %Intent.Glob{}), do: true
  defp condition_compatible?(:match_count_equals, %Intent.Grep{}), do: true
  defp condition_compatible?(:exit_code_equals, %Intent.RunCommand{}), do: true
  defp condition_compatible?(_condition, _intent), do: false
end
