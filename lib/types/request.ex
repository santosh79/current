defmodule Current.Request do
  @enforce_keys [:input, :context]
  defstruct [
    :input,
    :context
  ]

  @type t :: %__MODULE__{
          input: String.t() | map(),
          context: map()
        }
end
