defmodule Current.Event.ProposalValidationFailed do
  @enforce_keys [:id, :workflow_id, :proposal, :error, :timestamp]
  defstruct [:id, :workflow_id, :proposal, :error, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          proposal: Current.Proposal.t(),
          error: Current.Error.ValidationError.t(),
          timestamp: DateTime.t()
        }
end
