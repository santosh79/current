defmodule Current.ProposalBuilder do
  alias Current.{Id, Intent, Proposal, Request}

  @callback build(Request.t(), Current.Id.t()) :: {:ok, Proposal.t()} | {:error, term()}

  # SantoshTODO: Stop Hardcoding — replace with LLM-driven proposal generation
  def build(%Request{} = req, workflow_id) do
    proposal_id = Id.generate()

    dir = Path.join(System.tmp_dir!(), "current_proposal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "signup.ex")
    File.write!(path, "defmodule Signup do\nend\n")

    diff = """
    --- a/signup.ex
    +++ b/signup.ex
    @@ -1,2 +1,3 @@
     defmodule Signup do
    +  def validate_email(email), do: String.contains?(email, "@")
     end
    """

    {:ok, diff_artifact_id} = Current.BlobStore.put(diff)

    intent = %Intent.FilePatch{
      id: Id.generate(),
      proposal_id: proposal_id,
      path: path,
      diff_artifact_id: diff_artifact_id
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
