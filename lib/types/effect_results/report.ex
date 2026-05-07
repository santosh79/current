defmodule Current.EffectResult.Report do
  @enforce_keys [:generated]
  defstruct [:generated]
  @type t :: %__MODULE__{generated: boolean()}
end
