defmodule Current.Event.ModeInvalid do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :mode, :timestamp]
  defstruct [:id, :workflow_id, :mode, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          mode: term(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
