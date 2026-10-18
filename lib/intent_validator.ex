defmodule Current.IntentValidator do
  @moduledoc """
  Validates a decoded Proposal's intents before they become durable.

  This is deliberately narrower than "will this succeed when applied":
  validation protects the contract (referenced blobs exist, structural
  shape is sane, claims only cite earlier intents whose condition they
  could ever evaluate), not the world's future state. Whether a target
  file happens to already exist, or a command's executable happens to be
  on this box's PATH, can change between validation and apply -- those
  stay effect-time-only failures (see EffectApplicator), exactly as they
  already were before this module covered every intent type.

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

  @spec validate(Proposal.t(), Path.t()) :: :ok | {:error, ValidationError.t()}
  def validate(%Proposal{intents: intents}, project_dir) when is_binary(project_dir) do
    validate_helper(intents, %{}, Path.expand(project_dir))
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

  ## --- ReadFile -------------------------------------------------------

  defp validate_intent(%Intent.ReadFile{id: id, path: path}, _seen_intents) do
    case File.regular?(path) do
      true ->
        nil

      _ ->
        %ValidationError{
          intent_id: id,
          reason: "read_file path does not exist",
          details: %{path: path}
        }
    end
  end

  ## --- WriteFile --------------------------------------------------------
  # Whether `path` already exists is apply-time only (EffectApplicator
  # already handles it) -- it can change between now and apply, so
  # validating it here would just be a race with no real payoff.

  defp validate_intent(%Intent.WriteFile{id: id, contents_artifact_id: blob_id}, _seen_intents) do
    case BlobStore.path_for(blob_id) do
      {:ok, _path} ->
        nil

      {:error, :not_found} ->
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

  defp validate_intent(%Intent.DeleteFile{id: id, path: path}, _seen_intents) do
    case is_binary(path) and path != "" do
      true ->
        nil

      _ ->
        %ValidationError{
          intent_id: id,
          reason: "delete_file path must be a non-empty string",
          details: %{path: path}
        }
    end
  end

  ## --- EditFile -----------------------------------------------------------
  # More than "the path and blobs exist": the edit is checked against the
  # file as it is now (Current.Edit), so a human is never asked to approve
  # an edit that cannot apply. EffectApplicator checks again at apply time,
  # because the file can change in between. Two edits to one file in a
  # proposal are each checked against the file on disk, not against the
  # result of the earlier one.

  defp validate_intent(
         %Intent.EditFile{
           id: id,
           path: path,
           old_artifact_id: old_id,
           new_artifact_id: new_id,
           replace_all: replace_all
         },
         _seen_intents
       ) do
    with {:file, {:ok, contents}} <- {:file, File.read(path)},
         {:old, {:ok, old}} <- {:old, BlobStore.read(old_id)},
         {:new, {:ok, new}} <- {:new, BlobStore.read(new_id)},
         {:edit, {:ok, _edited, _count}} <-
           {:edit, Current.Edit.replace(contents, old, new, replace_all)} do
      nil
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

  defp validate_intent(%Intent.RunCommand{id: id, cmd: cmd, args: args}, _seen_intents) do
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
        nil
    end
  end

  ## --- Grep -------------------------------------------------------------

  defp validate_intent(%Intent.Grep{id: id, paths: paths}, _seen_intents) do
    case Enum.find(paths, &(not File.regular?(&1))) do
      nil ->
        nil

      path ->
        %ValidationError{
          intent_id: id,
          reason: "grep path does not exist",
          details: %{path: path}
        }
    end
  end

  ## --- Glob -------------------------------------------------------------

  defp validate_intent(%Intent.Glob{id: id, pattern: pattern, base_dir: base_dir}, _seen_intents) do
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
        nil
    end
  end

  ## --- Claim --------------------------------------------------------------
  # Structural only: does the evidence shape make sense, does it point at
  # an intent that already ran (by proposal order), and could this
  # condition ever be evaluated against *that kind* of intent at all?
  # Whether the *result* actually satisfies the condition is
  # EffectApplicator's job at apply time -- this is "can this claim in
  # principle be evaluated," not "will it pass."

  defp validate_intent(%Intent.Claim{id: id, evidence: nil}, _seen_intents) do
    %ValidationError{
      intent_id: id,
      reason: "claim requires evidence",
      details: %{}
    }
  end

  defp validate_intent(%Intent.Claim{id: id, evidence: evidence}, seen_intents) do
    source_intent_id = evidence_field(evidence, :source_intent_id)
    condition = evidence_field(evidence, :condition)

    cond do
      is_nil(source_intent_id) ->
        %ValidationError{
          intent_id: id,
          reason: "claim evidence missing source_intent_id",
          details: %{evidence: evidence}
        }

      not Map.has_key?(seen_intents, source_intent_id) ->
        %ValidationError{
          intent_id: id,
          reason: "claim references an intent that does not precede it in the proposal",
          details: %{source_intent_id: source_intent_id}
        }

      not condition_compatible?(condition, Map.fetch!(seen_intents, source_intent_id)) ->
        source_intent = Map.fetch!(seen_intents, source_intent_id)

        %ValidationError{
          intent_id: id,
          reason:
            "claim condition #{inspect(condition)} can never be evaluated against " <>
              "#{inspect(source_intent.__struct__)}",
          details: %{condition: condition, source_intent_id: source_intent_id}
        }

      true ->
        nil
    end
  end

  defp validate_intent(%Intent.Report{}, _seen_intents), do: nil

  defp validate_helper([], _seen_intents, _project_dir) do
    :ok
  end

  defp validate_helper([intent | rest], seen_intents, project_dir) do
    case validate_paths(intent, project_dir) || validate_intent(intent, seen_intents) do
      %ValidationError{} = error ->
        {:error, error}

      nil ->
        seen_intents = Map.put(seen_intents, intent.id, intent)
        validate_helper(rest, seen_intents, project_dir)
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

  ## --- Report -------------------------------------------------------------
end
