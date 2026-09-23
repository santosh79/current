defmodule Current.RaisingProposalBuilder do
  @behaviour Current.ProposalBuilder
  @impl true
  def build(_req, _workflow_id, _client_module, _timeout_ms, _project_dir), do: raise("model exploded")
end
