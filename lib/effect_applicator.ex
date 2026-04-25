defmodule Current.EffectApplicator do
  alias Current.Intent

  @callback apply(Intent.t()) :: {:ok, map()} | {:error, String.t()}
  @spec apply(Intent.t()) :: {:ok, map()} | {:error, String.t()}

  # SantoshTODO: implement real effect logic
  # SantoshTODO: See if this can be generated from Intent Types directly
  def apply(%Intent{type: :file_patch} = intent), do: {:ok, %{path: intent.payload.path}}
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
