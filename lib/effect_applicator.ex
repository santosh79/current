defmodule Current.EffectApplicator do
  @moduledoc """
  Performs one intent's side effect.

  `project_dir` is the authoritative boundary. Immediately before any
  filesystem access, every path the intent names must be absolute and --
  with all symlinks that exist *right now* followed -- inside
  `project_dir` (see Current.IntentPaths.resolved_violation/2). That is
  re-checked here even though IntentValidator already checked it
  lexically, because approval can come long after validation and the
  filesystem can change in between.

  Paths are never resolved here: WorkflowOrchestrator makes them
  absolute before the proposal is recorded, so a relative path arriving
  here is a bug upstream and is rejected, not guessed at.

  RunCommand runs with `project_dir` as its working directory. Its
  arguments are not path-checked -- a command can still reach outside the
  project by itself; only a sandbox can bound that.
  """

  import Kernel, except: [apply: 3]
  alias Current.{Intent, IntentPaths}

  @type result ::
          Current.EffectResult.FilePatch.t()
          | Current.EffectResult.WriteFile.t()
          | Current.EffectResult.DeleteFile.t()
          | Current.EffectResult.Command.t()
          | Current.EffectResult.ReadFile.t()
          | Current.EffectResult.Glob.t()
          | Current.EffectResult.Grep.t()
          | Current.EffectResult.Claim.t()
          | Current.EffectResult.Report.t()

  @callback apply(Intent.t(), [{Intent.t(), result()}], project_dir :: Path.t()) ::
              {:ok, result()} | {:error, String.t()}

  @spec apply(Intent.t(), [{Intent.t(), result()}], Path.t()) ::
          {:ok, result()} | {:error, String.t()}
  def apply(intent, prior_results, project_dir) when is_binary(project_dir) do
    case IntentPaths.resolved_violation(intent, project_dir) do
      nil ->
        do_apply(intent, prior_results, project_dir)

      {field, path, problem} ->
        {:error, "refusing to apply: #{field} #{inspect(path)} #{describe(problem)}"}
    end
  end

  defp describe(:not_absolute), do: "is not an absolute path"
  defp describe(:outside_project_dir), do: "resolves outside the project directory"
  defp describe(:parent_segment), do: "must not contain '..'"
  defp describe(:too_many_links), do: "has too many levels of symbolic links"

  defp do_apply(%Current.Intent.FilePatch{} = intent, _prior_results, _project_dir) do
    path = intent.path

    case File.exists?(path) do
      false ->
        {:error, "file not found: #{path}"}

      _ ->
        case System.find_executable("patch") do
          nil ->
            {:error, "patch executable not found on PATH"}

          patch_executable ->
            apply_patch(intent, path, patch_executable)
        end
    end
  end

  defp do_apply(%Current.Intent.ReadFile{} = intent, _prior_results, _project_dir) do
    case File.read(intent.path) do
      {:ok, contents} ->
        {:ok, artifact_id} = Current.BlobStore.put(contents)

        {:ok,
         %Current.EffectResult.ReadFile{
           path: intent.path,
           contents_artifact_id: artifact_id,
           bytes: byte_size(contents)
         }}

      {:error, :enoent} ->
        {:error, "file not found: #{intent.path}"}

      {:error, reason} ->
        {:error, "read_file failed for #{intent.path}: #{inspect(reason)}"}
    end
  end

  defp do_apply(%Current.Intent.WriteFile{} = intent, _prior_results, _project_dir) do
    case File.exists?(intent.path) do
      true ->
        {:error, "file already exists: #{intent.path}"}

      false ->
        case Current.BlobStore.read(intent.contents_artifact_id) do
          {:error, :not_found} ->
            {:error,
             "contents artifact not found for intent #{intent.id}: #{intent.contents_artifact_id}"}

          {:ok, contents} ->
            case write_file(intent.path, contents) do
              {:error, reason} ->
                {:error, "write_file failed for #{intent.path}: #{inspect(reason)}"}

              :ok ->
                {:ok, %Current.EffectResult.WriteFile{path: intent.path}}
            end
        end
    end
  end

  defp do_apply(%Current.Intent.DeleteFile{} = intent, _prior_results, _project_dir) do
    case File.dir?(intent.path) do
      true ->
        {:error, "delete_file failed for #{intent.path}: not a regular file"}

      _ ->
        case File.read(intent.path) do
          {:ok, contents} ->
            {:ok, before_artifact_id} = Current.BlobStore.put(contents)

            case delete_file(intent.path) do
              :ok ->
                {:ok,
                 %Current.EffectResult.DeleteFile{
                   path: intent.path,
                   before_artifact_id: before_artifact_id
                 }}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :enoent} ->
            # file doesn't exist — treat as already deleted, nothing to snapshot
            {:ok, %Current.EffectResult.DeleteFile{path: intent.path, before_artifact_id: nil}}

          {:error, reason} ->
            {:error, "delete_file failed to read #{intent.path}: #{inspect(reason)}"}
        end
    end
  end

  defp do_apply(%Current.Intent.RunCommand{} = intent, _prior_results, project_dir) do
    cmd = intent.cmd
    args = intent.args
    stdout_path = temp_path("stdout")
    stderr_path = temp_path("stderr")

    try do
      case run_command_with_redirect(cmd, args, stdout_path, stderr_path, project_dir) do
        {:ok, exit_code} ->
          stdout = File.read!(stdout_path)
          stderr = File.read!(stderr_path)

          with {:ok, stdout_artifact_id} <- Current.BlobStore.put(stdout),
               {:ok, stderr_artifact_id} <- Current.BlobStore.put(stderr) do
            {:ok,
             %Current.EffectResult.Command{
               exit_code: exit_code,
               stdout_artifact_id: stdout_artifact_id,
               stderr_artifact_id: stderr_artifact_id,
               stdout_bytes: byte_size(stdout),
               stderr_bytes: byte_size(stderr)
             }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm(stdout_path)
      File.rm(stderr_path)
    end
  end

  defp do_apply(%Current.Intent.Glob{} = intent, _prior_results, project_dir) do
    pattern = intent.pattern
    base_dir = intent.base_dir

    cond do
      Path.type(pattern) == :absolute ->
        {:error, "glob pattern must be relative"}

      not File.dir?(base_dir) ->
        {:error, "directory not found: #{base_dir}"}

      true ->
        # Traversing a symlinked directory can yield matches outside the
        # project even though base_dir itself is inside; drop those.
        matches =
          Path.join(base_dir, pattern)
          |> Path.wildcard()
          |> Enum.filter(&(IntentPaths.resolved_within(&1, project_dir) == :ok))
          |> Enum.sort()
        encoded = :erlang.term_to_binary(matches)
        {:ok, matches_artifact_id} = Current.BlobStore.put(encoded)

        {:ok,
         %Current.EffectResult.Glob{
           matches_artifact_id: matches_artifact_id,
           match_count: length(matches)
         }}
    end
  end

  defp do_apply(%Current.Intent.Grep{} = intent, _prior_results, _project_dir) do
    paths = intent.paths
    pattern = intent.pattern

    with :ok <- validate_paths_exist(paths) do
      searched_artifact_ids =
        Enum.map(paths, fn path ->
          {:ok, contents} = File.read(path)
          {:ok, artifact_id} = Current.BlobStore.put(contents)
          artifact_id
        end)

      matches =
        paths
        |> Enum.flat_map(fn path ->
          File.stream!(path, :line)
          |> Stream.with_index(1)
          |> Enum.filter(fn {line, _} -> String.contains?(line, pattern) end)
          |> Enum.map(fn {line, line_no} ->
            %Current.EffectResult.Grep.Match{
              path: path,
              line: line_no,
              text: String.trim_trailing(line)
            }
          end)
        end)

      encoded = :erlang.term_to_binary(matches)
      {:ok, matches_artifact_id} = Current.BlobStore.put(encoded)

      {:ok,
       %Current.EffectResult.Grep{
         matches_artifact_id: matches_artifact_id,
         match_count: length(matches),
         searched_artifact_ids: searched_artifact_ids
       }}
    end
  end

  defp do_apply(%Current.Intent.Report{} = _intent, _prior_results, _project_dir) do
    {:ok, %Current.EffectResult.Report{generated: true}}
  end

  defp do_apply(%Current.Intent.Claim{} = intent, prior_results, _project_dir) do
    case intent.evidence do
      nil ->
        {:error, "claim requires evidence"}

      evidence ->
        verify_evidence(intent.statement, evidence, prior_results)
    end
  end

  defp do_apply(%{__struct__: mod} = _intent, _prior_results, _project_dir),
    do: {:error, "unsupported intent type: #{mod}"}

  defp run_command_with_redirect(cmd, args, stdout_path, stderr_path, project_dir) do
    executable = System.find_executable(command_path(cmd, project_dir))

    case executable do
      nil ->
        {:error, "command not found: #{cmd}"}

      _ ->
        script = """
        exec "$1" "${@:4}" > "$2" 2> "$3"
        """

        {_output, exit_code} =
          System.cmd(
            "bash",
            ["-c", script, "current-runner", executable, stdout_path, stderr_path | args],
            stderr_to_stdout: true,
            cd: project_dir
          )

        {:ok, exit_code}
    end
  rescue
    e ->
      {:error, "command failed: #{Exception.message(e)}"}
  end

  # A bare name ("mix") is looked up on PATH as before. A relative path
  # ("bin/setup") means relative to the project, not to this node's cwd.
  defp command_path(cmd, project_dir) do
    if String.contains?(cmd, "/") and Path.type(cmd) == :relative,
      do: Path.expand(cmd, project_dir),
      else: cmd
  end

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "current_#{label}_#{System.unique_integer([:positive])}.txt"
    )
  end

  defp write_file(path, contents) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents) do
      :ok
    end
  end

  defp delete_file(path) do
    case File.exists?(path) do
      true -> File.rm(path)
      _ -> :ok
    end
  end

  defp validate_paths_exist(paths) do
    case Enum.find(paths, &(not File.regular?(&1))) do
      nil ->
        :ok

      path ->
        {:error, "file not found: #{path}"}
    end
  end

  defp verify_evidence(statement, evidence, prior_results) do
    source_intent_id = Map.fetch!(evidence, :source_intent_id)
    condition = Map.fetch!(evidence, :condition)
    value = Map.fetch!(evidence, :value)

    case find_prior_result_by_intent_id(prior_results, source_intent_id) do
      nil ->
        {:error, "claim evidence references #{source_intent_id} but no such intent result found"}

      prior_result ->
        evaluate_condition(statement, evidence, condition, value, prior_result)
    end
  end

  defp find_prior_result_by_intent_id(prior_results, source_intent_id) do
    case Enum.find(prior_results, fn {intent, _result} -> intent.id == source_intent_id end) do
      {_intent, result} -> result
      nil -> nil
    end
  end

  defp evaluate_condition(
         statement,
         evidence,
         :match_count_greater_than,
         value,
         %Current.EffectResult.Grep{} = result
       ) do
    verified = result.match_count > value
    reason = "grep produced #{result.match_count} match(es), expected more than #{value}"

    {:ok,
     %Current.EffectResult.Claim{
       verified: verified,
       statement: statement,
       reason: reason,
       evidence: evidence
     }}
  end

  defp evaluate_condition(
         statement,
         evidence,
         :match_count_greater_than,
         value,
         %Current.EffectResult.Glob{} = result
       ) do
    verified = result.match_count > value
    reason = "glob produced #{result.match_count} match(es), expected more than #{value}"

    {:ok,
     %Current.EffectResult.Claim{
       verified: verified,
       statement: statement,
       reason: reason,
       evidence: evidence
     }}
  end

  defp evaluate_condition(
         statement,
         evidence,
         :match_count_equals,
         value,
         %Current.EffectResult.Grep{} = result
       ) do
    verified = result.match_count == value
    reason = "grep produced #{result.match_count} match(es), expected exactly #{value}"

    {:ok,
     %Current.EffectResult.Claim{
       verified: verified,
       statement: statement,
       reason: reason,
       evidence: evidence
     }}
  end

  defp evaluate_condition(
         statement,
         evidence,
         :exit_code_equals,
         value,
         %Current.EffectResult.Command{} = result
       ) do
    verified = result.exit_code == value
    reason = "command exited with #{result.exit_code}, expected #{value}"

    {:ok,
     %Current.EffectResult.Claim{
       verified: verified,
       statement: statement,
       reason: reason,
       evidence: evidence
     }}
  end

  defp evaluate_condition(_statement, _evidence, condition, _value, result) do
    {:error, "condition #{condition} is not supported for #{result.__struct__}"}
  end

  defp apply_patch(intent, path, patch_executable) do
    case Current.BlobStore.read(intent.diff_artifact_id) do
      {:error, :not_found} ->
        {:error, "diff artifact not found for intent #{intent.id}: #{intent.diff_artifact_id}"}

      {:ok, diff} ->
        before_contents = File.read!(path)
        {:ok, before_artifact_id} = Current.BlobStore.put(before_contents)

        patch_path =
          Path.join(
            System.tmp_dir!(),
            "current_patch_#{System.unique_integer([:positive])}.diff"
          )

        try do
          :ok = File.write!(patch_path, diff)

          {_output, exit_code} =
            System.cmd(patch_executable, ["--batch", "--forward", "--fuzz=0", path, patch_path],
              stderr_to_stdout: true
            )

          case exit_code do
            0 ->
              after_contents = File.read!(path)
              {:ok, after_artifact_id} = Current.BlobStore.put(after_contents)

              {:ok,
               %Current.EffectResult.FilePatch{
                 path: path,
                 before_artifact_id: before_artifact_id,
                 after_artifact_id: after_artifact_id
               }}

            _ ->
              {:error, "effect patch: #{intent.id} failed with exit code #{exit_code}"}
          end
        after
          :ok = File.rm(patch_path)
        end
    end
  end
end
