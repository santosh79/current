defmodule Current.ErrorReturningProposalBuilder do
  @behaviour Current.ProposalBuilder
  @impl true
  def build(_req, _workflow_id), do: {:error, :rate_limited}
end
