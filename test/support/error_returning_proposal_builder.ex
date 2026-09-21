defmodule Current.ErrorReturningProposalBuilder do
  @behaviour Current.ProposalBuilder
  alias Current.Error.ProposalProductionError

  @impl true
  def build(_req, _workflow_id, _client_module),
    do: {:error, %ProposalProductionError{stage: :connection, reason: :rate_limited}}
end
