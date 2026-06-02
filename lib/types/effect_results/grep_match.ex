defmodule Current.EffectResult.Grep.Match do
  @enforce_keys [:path, :line, :text]
  defstruct [:path, :line, :text]

  @type t :: %__MODULE__{
          path: String.t(),
          line: pos_integer(),
          text: String.t()
        }
end
