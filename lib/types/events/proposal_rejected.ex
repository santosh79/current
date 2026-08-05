defmodule Current.Event.ProposalRejected do
  @enforce_keys [:id, :workflow_id, :timestamp]
  defstruct [:id, :workflow_id, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          timestamp: DateTime.t()
        }
end
