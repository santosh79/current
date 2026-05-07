defmodule Current.EffectResult.FilePatch do
  @enforce_keys [:path]
  defstruct [:path]
  @type t :: %__MODULE__{path: String.t()}
end
