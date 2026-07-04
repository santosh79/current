defmodule Current.Event.WorkflowFailed do
  @enforce_keys [:id, :workflow_id, :workflow, :timestamp]
  defstruct [:id, :workflow_id, :workflow, :reason, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          workflow: Current.Workflow.t(),
          reason: String.t(),
          timestamp: DateTime.t()
        }
end
