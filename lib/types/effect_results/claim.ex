defmodule Current.EffectResult.Claim do
  @enforce_keys [:verified]
  defstruct [:verified]
  @type t :: %__MODULE__{verified: boolean()}
end
