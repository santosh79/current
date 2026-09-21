defmodule Current.BlockingProposalBuilder do
  @behaviour Current.ProposalBuilder
  @impl true
  def build(_req, _workflow_id, _client_module), do: Process.sleep(:infinity)
end
