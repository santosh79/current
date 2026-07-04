defmodule Current.Event.WorkflowCreated do
  @enforce_keys [:id, :workflow_id, :workflow, :timestamp]
  defstruct [:id, :workflow_id, :task_id, :mode, :workflow, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          task_id: Current.Id.t(),
          mode: Current.Mode.t(),
          workflow: Current.Workflow.t(),
          timestamp: DateTime.t()
        }
end
