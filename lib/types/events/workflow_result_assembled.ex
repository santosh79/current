defmodule Current.Event.WorkflowResultAssembled do
  @enforce_keys [:id, :workflow_id, :workflow, :result, :timestamp]
  defstruct [:id, :workflow_id, :workflow, :result, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          workflow: Current.Workflow.t(),
          result: Current.WorkflowResult.t(),
          timestamp: DateTime.t()
        }
end
