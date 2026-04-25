defmodule Current.SecondIntentFailsProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "SecondIntentFailsProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    intents = [
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :file_patch,
        payload: %{path: "lib/stub.ex", diff: "..."}
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :file_patch,
        payload: %{path: "lib/stub.ex", diff: "...", force_failure: true}
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :run_command,
        payload: %{command: "mix test"}
      }
    ]

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: intents,
       justification: "Proposed changes for request: #{inspect(req.input)}",
       claims: [],
       dependencies: []
     }}
  end
end
