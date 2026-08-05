defmodule Current.Event.ProposalValidated do
  @enforce_keys [:id, :workflow_id, :proposal, :timestamp]
  defstruct [:id, :workflow_id, :proposal, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          proposal: Current.Proposal.t(),
          timestamp: DateTime.t()
        }
end
