defmodule Current.RaisingProposalBuilder do
  @behaviour Current.ProposalBuilder
  @impl true
  def build(_req, _workflow_id, _client_module), do: raise("model exploded")
end
