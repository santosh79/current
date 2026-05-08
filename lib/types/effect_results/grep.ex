defmodule Current.EffectResult.Grep.Match do
  @enforce_keys [:path, :line, :text]
  defstruct [:path, :line, :text]

  @type t :: %__MODULE__{
          path: String.t(),
          line: pos_integer(),
          text: String.t()
        }
end

defmodule Current.EffectResult.Grep do
  alias Current.EffectResult.Grep.Match

  @enforce_keys [:matches]
  defstruct [:matches]

  @type t :: %__MODULE__{
          matches: [Match.t()]
        }
end
