defmodule Current.Event.ProposalRejected do
  @enforce_keys [:id, :workflow_id, :workflow, :timestamp]
  defstruct [:id, :workflow_id, :workflow, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          workflow: Current.Workflow.t(),
          timestamp: DateTime.t()
        }
end
