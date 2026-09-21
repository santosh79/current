defmodule Current.RunCommandProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id, _client_module) do
    unless Mix.env() == :test do
      raise "RunCommandProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    intent = %Intent.RunCommand{
      id: Id.generate(),
      proposal_id: proposal_id,
      cmd: "sh",
      args: ["-c", "echo hello from test; echo error from test >&2"]
    }

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: [intent],
       justification: "Run a command for request: #{inspect(req.input)}",
       claims: [],
       dependencies: []
     }}
  end
end
