defmodule Current.Event.WorkflowResultAssembled do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :result, :timestamp]
  defstruct [:id, :workflow_id, :result, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          result: Current.WorkflowResult.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
