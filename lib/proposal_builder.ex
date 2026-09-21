defmodule Current.ProposalBuilder do

  @callback build(Current.Request.t(), Current.Id.t(), module()) ::
            {:ok, Current.Proposal.t()}
            | {:ok, Current.Proposal.t(), Current.Id.t()}
            | {:error, Current.Error.ProposalProductionError.t()}
end
