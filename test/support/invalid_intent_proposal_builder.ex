defmodule Current.InvalidIntentProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "InvalidIntentProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    intent = %Intent.ReadFile{
      id: Id.generate(),
      proposal_id: proposal_id,
      path:
        Path.join(
          System.tmp_dir!(),
          "current_missing_file_#{System.unique_integer([:positive])}.txt"
        )
    }

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: [intent],
       justification: "Invalid proposal for request: #{inspect(req.input)}",
       claims: [],
       dependencies: []
     }}
  end
end
