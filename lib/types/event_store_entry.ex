defmodule Current.EventStore.Entry do
  @enforce_keys [:position, :event, :inserted_at]
  defstruct [:position, :event, :inserted_at]

  @type t :: %__MODULE__{
          position: non_neg_integer(),
          event: Current.Event.t(),
          inserted_at: DateTime.t()
        }
end
