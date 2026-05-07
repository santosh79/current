defmodule Current.EffectResult.Grep do
  @enforce_keys [:matches]
  defstruct [:matches]
  @type t :: %__MODULE__{matches: [String.t()]}
end
