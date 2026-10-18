defmodule Current.FakeProposalBuilder do
  @behaviour Current.ProposalBuilder

  @impl true
  @spec build(Request.t(), Current.Id.t(), module(), pos_integer(), Path.t() | nil) ::
          {:ok, Proposal.t()}
          | {:ok, Proposal.t(), Current.Id.t()}
          | {:error, ProposalProductionError.t()}
  def build(%Current.Request{} = req, workflow_id, _module, _timeout_ms, _project_dir) do
    proposal_id = Current.Id.generate()

    # Canonical, like the project_dir submit_task records for the tmp dir
    # (on macOS System.tmp_dir!() is under /var, a symlink to /private/var).
    {:ok, tmp} = Current.IntentPaths.realpath(Path.expand(System.tmp_dir!()))
    dir = Path.join(tmp, "current_proposal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "signup.ex")
    File.write!(path, "defmodule Signup do\nend\n")

    old_string = "defmodule Signup do\n"

    new_string =
      "defmodule Signup do\n  def validate_email(email), do: String.contains?(email, \"@\")\n"

    {:ok, old_artifact_id} = Current.BlobStore.put(old_string)
    {:ok, new_artifact_id} = Current.BlobStore.put(new_string)

    intent = %Current.Intent.EditFile{
      id: Current.Id.generate(),
      proposal_id: proposal_id,
      path: path,
      old_artifact_id: old_artifact_id,
      new_artifact_id: new_artifact_id
    }

    proposal = %Current.Proposal{
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
