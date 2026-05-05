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

  def apply(%Intent{type: :write_file} = intent),
    do: {:ok, %Current.EffectResult.WriteFile{path: intent.payload.path}}

  def apply(%Intent{type: :delete_file} = intent),
    do: {:ok, %Current.EffectResult.DeleteFile{path: intent.payload.path}}

  def apply(%Intent{type: :run_command} = intent) do
    cmd = Map.fetch!(intent.payload, :cmd)
    args = Map.get(intent.payload, :args, [])

    stdout_path =
      Path.join(System.tmp_dir!(), "current_stdout_#{System.unique_integer([:positive])}.txt")

    stderr_path =
      Path.join(System.tmp_dir!(), "current_stderr_#{System.unique_integer([:positive])}.txt")

    script =
      Enum.join(
        [
          shell_escape(cmd),
          Enum.map_join(args, " ", &shell_escape/1),
          ">",
          shell_escape(stdout_path),
          "2>",
          shell_escape(stderr_path)
        ],
        " "
      )

    try do
      {_output, exit_code} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)

      stdout = File.read!(stdout_path)
      stderr = File.read!(stderr_path)

      {:ok, stdout_artifact_id} = Current.ArtifactStore.put("stdout.txt", stdout)
      {:ok, stderr_artifact_id} = Current.ArtifactStore.put("stderr.txt", stderr)

      {:ok,
       %Current.EffectResult.Command{
         exit_code: exit_code,
         stdout_artifact_id: stdout_artifact_id,
         stderr_artifact_id: stderr_artifact_id,
         stdout_bytes: byte_size(stdout),
         stderr_bytes: byte_size(stderr)
       }}
    rescue
      e ->
        {:error, "command failed: #{Exception.message(e)}"}
    after
      File.rm(stdout_path)
      File.rm(stderr_path)
    end
  end

  def apply(%Intent{type: :glob} = _intent),
    do: {:ok, %Current.EffectResult.Glob{matches: []}}

  def apply(%Intent{type: :grep} = _intent),
    do: {:ok, %Current.EffectResult.Grep{matches: []}}

  def apply(%Intent{type: :claim} = _intent),
    do: {:ok, %Current.EffectResult.Claim{verified: true}}

  def apply(%Intent{type: :report} = _intent),
    do: {:ok, %Current.EffectResult.Report{generated: true}}

  def apply(%Intent{type: type}), do: {:error, "unsupported intent type: #{type}"}

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
