defmodule Current.Request do
  @enforce_keys [:input, :context]
  defstruct [
    :input,
    :context,
    mode: Current.Mode.default()
  ]

  @type t :: %__MODULE__{
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t()
        }
end
