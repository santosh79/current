defmodule Current.ProposalBuilder do
  alias Current.{Id, Intent, Proposal, Request}

  @callback build(Request.t(), Current.Id.t()) :: {:ok, Proposal.t()} | {:error, term()}

  # SantoshTODO: Stop Hardcoding
  def build(%Request{} = req, workflow_id) do
    proposal_id = Id.generate()


    intent = %Intent{
      id: Id.generate(),
      proposal_id: proposal_id,
      type: :file_patch,
      payload: %{
        path: "lib/my_app/signup.ex",
        diff: "...diff..."
      }
    }

    proposal = %Proposal{
      id: proposal_id,
      workflow_id: workflow_id,
      intents: [intent],
      justification: "Proposed changes for request: #{inspect(req.input)}",
      claims: [
        "invalid emails are rejected",
        "existing behavior is unchanged"
      ],
      dependencies: []
    }
    {:ok, proposal}
  end
end
