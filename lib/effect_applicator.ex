defmodule Current.EffectApplicator do
  import Kernel, except: [apply: 2]
  alias Current.Intent

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

  def apply(intent) do
    __MODULE__.apply(intent, [])
  end

  @callback apply(Intent.t(), [{Intent.t(), result()}]) :: {:ok, result()} | {:error, String.t()}
  @spec apply(Intent.t(), [{Intent.t(), result()}]) :: {:ok, result()} | {:error, String.t()}

  def apply(%Current.Intent.FilePatch{} = intent, _prior_results) do
    path = intent.path

    unless File.exists?(path) do
      {:error, "file not found: #{path}"}
    else
      diff = intent.diff

      patch_path =
        Path.join(System.tmp_dir!(), "current_patch_#{System.unique_integer([:positive])}.diff")

      :ok = File.write!(patch_path, diff)

      try do
        case System.cmd("patch", ["--batch", "--forward", path, patch_path],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            {:ok, %Current.EffectResult.FilePatch{path: path}}

          {output, exit_code} ->
            {:error, "patch failed with exit code #{exit_code}: #{String.trim(output)}"}
        end
      after
        File.rm(patch_path)
      end
    end
  end

  def apply(%Current.Intent.ReadFile{} = intent, _prior_results) do
    case File.read(intent.path) do
      {:ok, contents} ->
        {:ok, artifact_id} = Current.ArtifactStore.put(contents)

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

  def apply(%Current.Intent.WriteFile{} = intent, _prior_results) do
    case File.exists?(intent.path) do
      true ->
        {:error, "file already exists: #{intent.path}"}

      false ->
        case write_file(intent.path, intent.contents) do
          :ok -> {:ok, %Current.EffectResult.WriteFile{path: intent.path}}
          {:error, reason} -> {:error, "write_file failed for #{intent.path}: #{inspect(reason)}"}
        end
    end
  end

  def apply(%Current.Intent.DeleteFile{} = intent, _prior_results) do
    case File.dir?(intent.path) do
      true ->
        {:error, "delete_file failed for #{intent.path}: not a regular file"}

      _ ->
        case delete_file(intent.path) do
          :ok -> {:ok, %Current.EffectResult.DeleteFile{path: intent.path}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def apply(%Current.Intent.RunCommand{} = intent, _prior_results) do
    cmd = intent.cmd
    args = intent.args
    stdout_path = temp_path("stdout")
    stderr_path = temp_path("stderr")

    try do
      case run_command_with_redirect(cmd, args, stdout_path, stderr_path) do
        {:ok, exit_code} ->
          stdout = File.read!(stdout_path)
          stderr = File.read!(stderr_path)

          with {:ok, stdout_artifact_id} <- Current.ArtifactStore.put(stdout),
               {:ok, stderr_artifact_id} <- Current.ArtifactStore.put(stderr) do
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

  def apply(%Current.Intent.Glob{} = intent, _prior_results) do
    pattern = intent.pattern
    base_dir = intent.base_dir

    cond do
      Path.type(pattern) == :absolute ->
        {:error, "glob pattern must be relative"}

      not File.dir?(base_dir) ->
        {:error, "directory not found: #{base_dir}"}

      true ->
        matches = Path.join(base_dir, pattern) |> Path.wildcard() |> Enum.sort()
        {:ok, %Current.EffectResult.Glob{matches: matches}}
    end
  end

  def apply(%Current.Intent.Grep{} = intent, _prior_results) do
    pattern = intent.pattern
    paths = intent.paths

    with :ok <- validate_paths_exist(paths) do
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

      {:ok, %Current.EffectResult.Grep{matches: matches}}
    end
  end

  def apply(%Current.Intent.Report{} = _intent, _prior_results) do
    {:ok, %Current.EffectResult.Report{generated: true}}
  end

  def apply(%Current.Intent.Claim{} = intent, prior_results) do
    case intent.evidence do
      nil ->
        case intent.expected do
          expected when is_boolean(expected) ->
            {:ok,
             %Current.EffectResult.Claim{
               verified: expected,
               statement: intent.statement,
               reason: "asserted directly"
             }}

          nil ->
            {:error, "claim requires either :evidence or :expected"}

          _ ->
            {:error, "claim expected must be a boolean"}
        end

      evidence ->
        verify_evidence(intent.statement, evidence, prior_results)
    end
  end

  def apply(%{__struct__: mod} = _intent, _prior_results),
    do: {:error, "unsupported intent type: #{mod}"}

  defp run_command_with_redirect(cmd, args, stdout_path, stderr_path) do
    executable = System.find_executable(cmd)

    if executable == nil do
      {:error, "command not found: #{cmd}"}
    else
      script = """
      exec "$1" "${@:4}" > "$2" 2> "$3"
      """

      {_output, exit_code} =
        System.cmd(
          "bash",
          ["-c", script, "current-runner", executable, stdout_path, stderr_path | args],
          stderr_to_stdout: true
        )

      {:ok, exit_code}
    end
  rescue
    e ->
      {:error, "command failed: #{Exception.message(e)}"}
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
    count = length(result.matches)
    verified = count > value
    reason = "grep produced #{count} match(es), expected more than #{value}"

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
    count = length(result.matches)
    verified = count > value
    reason = "glob produced #{count} match(es), expected more than #{value}"

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
    count = length(result.matches)
    verified = count == value
    reason = "grep produced #{count} match(es), expected exactly #{value}"

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
end
