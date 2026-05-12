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


  @callback apply(Intent.t()) :: {:ok, result()} | {:error, String.t()}
  @spec apply(Intent.t()) :: {:ok, result()} | {:error, String.t()}
  def apply(%Intent{} = intent), do: apply(intent, [])

  @callback apply(Intent.t(), [{Intent.t(), result()}]) :: {:ok, result()} | {:error, String.t()}
  @spec apply(Intent.t(), [{Intent.t(), result()}]) :: {:ok, result()} | {:error, String.t()}

  def apply(%Intent{type: :file_patch} = intent, _prior_results) do
    path = intent.payload.path
    diff = intent.payload.diff

    unless File.exists?(path) do
      {:error, "file not found: #{path}"}
    else
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

  def apply(%Intent{type: :write_file} = intent, _prior_results) do
    path = Map.fetch!(intent.payload, :path)

    case File.exists?(path) do
      true ->
        {:error, "file already exists: #{path}"}

      false ->
        contents = Map.fetch!(intent.payload, :contents)

        case write_file(path, contents) do
          :ok -> {:ok, %Current.EffectResult.WriteFile{path: path}}
          {:error, reason} -> {:error, "write_file failed for #{path}: #{inspect(reason)}"}
        end
    end
  end

  def apply(%Intent{type: :delete_file} = intent, _prior_results) do
    path = Map.fetch!(intent.payload, :path)

    case File.dir?(path) do
      true ->
        {:error, "delete_file failed for #{path}: not a regular file"}

      _ ->
        case delete_file(path) do
          :ok -> {:ok, %Current.EffectResult.DeleteFile{path: path}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def apply(%Intent{type: :run_command} = intent, _prior_results) do
    cmd = Map.fetch!(intent.payload, :cmd)
    args = Map.get(intent.payload, :args, [])

    stdout_path = temp_path("stdout")
    stderr_path = temp_path("stderr")

    try do
      case run_command_with_redirect(cmd, args, stdout_path, stderr_path) do
        {:ok, exit_code} ->
          stdout = File.read!(stdout_path)
          stderr = File.read!(stderr_path)

          with {:ok, stdout_artifact_id} <- Current.ArtifactStore.put("stdout.txt", stdout),
               {:ok, stderr_artifact_id} <- Current.ArtifactStore.put("stderr.txt", stderr) do
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

  def apply(%Intent{type: :glob} = intent, _prior_results) do
    pattern = Map.fetch!(intent.payload, :pattern)
    base_dir = Map.get(intent.payload, :base_dir, ".")

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

  def apply(%Intent{type: :grep} = intent, _prior_results) do
    pattern = Map.fetch!(intent.payload, :pattern)
    paths = Map.fetch!(intent.payload, :paths)

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

  def apply(%Intent{type: :report} = _intent, _prior_results),
    do: {:ok, %Current.EffectResult.Report{generated: true}}

  def apply(%Intent{type: :claim} = intent, prior_results) do
    statement = Map.get(intent.payload, :statement, Map.get(intent.payload, :claim, ""))

    case Map.fetch(intent.payload, :evidence) do
      {:ok, evidence} ->
        verify_evidence(statement, evidence, prior_results)

      :error ->
        case Map.fetch(intent.payload, :expected) do
          {:ok, expected} when is_boolean(expected) ->
            {:ok,
             %Current.EffectResult.Claim{
               verified: expected,
               statement: statement,
               reason: "asserted directly"
             }}

          {:ok, _other} ->
            {:error, "claim expected must be a boolean"}

          :error ->
            {:error, "claim requires either :evidence or :expected"}
        end
    end
  end

  def apply(%Intent{type: type}, _prior_results),
    do: {:error, "unsupported intent type: #{type}"}

  # ... private functions unchanged ...
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
    intent_type = Map.fetch!(evidence, :intent_type)
    condition = Map.fetch!(evidence, :condition)
    value = Map.fetch!(evidence, :value)

    case find_prior_result(prior_results, intent_type) do
      nil ->
        {:error, "claim evidence references #{intent_type} but no such intent result found"}

      prior_result ->
        evaluate_condition(statement, condition, value, prior_result)
    end
  end

  defp find_prior_result(prior_results, intent_type) do
    case Enum.find(prior_results, fn {intent, _result} -> intent.type == intent_type end) do
      {_intent, result} -> result
      nil -> nil
    end
  end

  defp evaluate_condition(
         statement,
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
       evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: value}
     }}
  end

  defp evaluate_condition(
         statement,
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
       evidence: %{intent_type: :glob, condition: :match_count_greater_than, value: value}
     }}
  end

  defp evaluate_condition(
         statement,
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
       evidence: %{intent_type: :grep, condition: :match_count_equals, value: value}
     }}
  end

  defp evaluate_condition(
         statement,
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
       evidence: %{intent_type: :run_command, condition: :exit_code_equals, value: value}
     }}
  end

  defp evaluate_condition(_statement, condition, _value, result) do
    {:error, "condition #{condition} is not supported for #{result.__struct__}"}
  end
end

