defmodule Current.EffectResult.Glob do
  @enforce_keys [:matches]
  defstruct [:matches]
  @type t :: %__MODULE__{matches: [String.t()]}
end
