defmodule Current.Event.WorkflowFailed do
  @enforce_keys [:id, :workflow_id, :timestamp]
  defstruct [:id, :workflow_id, :reason, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          reason: String.t(),
          timestamp: DateTime.t()
        }
end
