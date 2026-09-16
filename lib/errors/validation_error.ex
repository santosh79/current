defmodule Current.Error.ValidationError do
  @enforce_keys [:intent_id, :reason]
  defstruct [:intent_id, :reason, details: %{}]

  @type t :: %__MODULE__{
          intent_id: Current.Id.t(),
          reason: String.t(),
          details: map()
        }
end
