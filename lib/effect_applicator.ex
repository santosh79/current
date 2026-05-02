defmodule Current.EffectApplicator do
  alias Current.Intent

  @callback apply(Intent.t()) :: {:ok, map()} | {:error, String.t()}
  @spec apply(Intent.t()) :: {:ok, map()} | {:error, String.t()}

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
            {:ok, %{path: path}}

          {output, exit_code} ->
            {:error, "patch failed with exit code #{exit_code}: #{String.trim(output)}"}
        end
      after
        File.rm(patch_path)
      end
    end
  end

  def apply(%Intent{type: :write_file} = intent), do: {:ok, %{path: intent.payload.path}}
  def apply(%Intent{type: :delete_file} = intent), do: {:ok, %{path: intent.payload.path}}
  def apply(%Intent{type: :run_command} = _intent), do: {:ok, %{exit_code: 0}}
  def apply(%Intent{type: :read_file} = intent), do: {:ok, %{path: intent.payload.path}}
  def apply(%Intent{type: :glob} = _intent), do: {:ok, %{matches: []}}
  def apply(%Intent{type: :grep} = _intent), do: {:ok, %{matches: []}}
  def apply(%Intent{type: :claim} = _intent), do: {:ok, %{verified: true}}
  def apply(%Intent{type: :report} = _intent), do: {:ok, %{generated: true}}
  def apply(%Intent{type: type}), do: {:error, "unsupported intent type: #{type}"}
end
