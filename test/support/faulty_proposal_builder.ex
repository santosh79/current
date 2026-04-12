defmodule Current.FaultyProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "FaultyProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    intent = %Intent{
      id: Id.generate(),
      proposal_id: proposal_id,
      type: :drop_database,
      payload: %{}
    }

    faulty_proposal = %Proposal{
      id: proposal_id,
      workflow_id: workflow_id,
      intents: [intent],
      justification: "Proposed changes for request: #{inspect(req.input)}",
      claims: [],
      dependencies: []
    }

    {:ok, faulty_proposal}
  end
end
