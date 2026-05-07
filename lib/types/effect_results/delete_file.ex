defmodule Current.EffectResult.DeleteFile do
  @enforce_keys [:path]
  defstruct [:path]
  @type t :: %__MODULE__{path: String.t()}
end
