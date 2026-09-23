defmodule Current.FaultyProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id, _client_module, _timeout_ms, _project_dir) do
    unless Mix.env() == :test do
      raise "FaultyProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()
    missing_file_path =
      Path.join(Current.TestTmp.dir(), "current_missing_file_#{System.unique_integer([:positive])}.ex")

    intent = %Intent.ReadFile{
      id: Id.generate(),
      proposal_id: proposal_id,
      path: missing_file_path
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
