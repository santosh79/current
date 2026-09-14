defmodule Current.Event.ProposalProductionStarted do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :timestamp]
  defstruct [:id, :workflow_id, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
