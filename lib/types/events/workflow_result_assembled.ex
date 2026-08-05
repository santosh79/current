defmodule Current.Event.WorkflowResultAssembled do
  @enforce_keys [:id, :workflow_id, :result, :timestamp]
  defstruct [:id, :workflow_id, :result, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          result: Current.WorkflowResult.t(),
          timestamp: DateTime.t()
        }
end
