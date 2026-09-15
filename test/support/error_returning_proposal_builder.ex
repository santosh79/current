defmodule Current.ErrorReturningProposalBuilder do
  @behaviour Current.ProposalBuilder
  alias Current.ProposalProductionError

  @impl true
  def build(_req, _workflow_id),
    do: {:error, %ProposalProductionError{stage: :connection, reason: :rate_limited}}
end
