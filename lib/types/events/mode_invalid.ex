defmodule Current.Event.ModeInvalid do
  @enforce_keys [:id, :workflow_id, :mode, :timestamp]
  defstruct [:id, :workflow_id, :mode, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          mode: term(),
          timestamp: DateTime.t()
        }
end
