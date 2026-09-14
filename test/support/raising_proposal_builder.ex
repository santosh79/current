defmodule Current.RaisingProposalBuilder do
  @behaviour Current.ProposalBuilder
  @impl true
  def build(_req, _workflow_id), do: raise("model exploded")
end
