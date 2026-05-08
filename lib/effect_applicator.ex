defmodule Current.EffectApplicator do
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

  # SantoshTODO: implement real effect logic
  # SantoshTODO: See if this can be generated from Intent Types directly
  def apply(%Intent{type: :file_patch} = intent) do
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

  def apply(%Intent{type: :write_file} = intent) do
    path = Map.fetch!(intent.payload, :path)

    case File.exists?(path) do
      true ->
        {:error, "file already exists: #{path}"}

      false ->
        contents = Map.fetch!(intent.payload, :contents)

        case write_file(path, contents) do
          :ok ->
            {:ok, %Current.EffectResult.WriteFile{path: path}}

          {:error, reason} ->
            {:error, "write_file failed for #{path}: #{inspect(reason)}"}
        end
    end
  end

  def apply(%Intent{type: :delete_file} = intent) do
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

  def apply(%Intent{type: :run_command} = intent) do
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

  def apply(%Intent{type: :glob} = _intent),
    do: {:ok, %Current.EffectResult.Glob{matches: []}}

  def apply(%Intent{type: :grep} = intent) do
    pattern = Map.fetch!(intent.payload, :pattern)
    paths = Map.fetch!(intent.payload, :paths)

    with :ok <- validate_paths_exist(paths) do
      matches =
        paths
        |> Enum.flat_map(fn path ->
          path
          |> File.stream!([], :line)
          |> Stream.with_index(1)
          |> Enum.flat_map(fn {line, line_no} ->
            if String.contains?(line, pattern) do
              [
                %Current.EffectResult.Grep.Match{
                  path: path,
                  line: line_no,
                  text: String.trim_trailing(line)
                }
              ]
            else
              []
            end
          end)
        end)

      {:ok, %Current.EffectResult.Grep{matches: matches}}
    end
  end

  def apply(%Intent{type: :claim} = _intent),
    do: {:ok, %Current.EffectResult.Claim{verified: true}}

  def apply(%Intent{type: :report} = _intent),
    do: {:ok, %Current.EffectResult.Report{generated: true}}

  def apply(%Intent{type: type}), do: {:error, "unsupported intent type: #{type}"}

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
end
