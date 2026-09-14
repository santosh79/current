defmodule Current.BlockingProposalBuilder do
  @behaviour Current.ProposalBuilder
  @impl true
  def build(_req, _workflow_id), do: Process.sleep(:infinity)
end
