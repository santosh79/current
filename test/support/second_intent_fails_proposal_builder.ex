defmodule Current.SecondIntentFailsProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  defp make_test_dir do
    suffix =
      Current.Id.generate()
      |> String.replace(":", "-")

    dir =
      Path.join(
        Current.TestTmp.dir(),
        "current_multi_#{suffix}"
      )

    :ok = File.mkdir_p!(dir)
    dir
  end

  @impl true
  def build(%Request{} = req, workflow_id, _client_module, _timeout_ms, _project_dir) do
    unless Mix.env() == :test do
      raise "SecondIntentFailsProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    dir = make_test_dir()

    patch_path = Path.join(dir, "stub.ex")
    :ok = File.write!(patch_path, "defmodule Stub do\nend\n")

    already_existing_path = Path.join(dir, "already_existing.ex")
    :ok = File.write!(already_existing_path, "defmodule Existing do\nend\n")

    {:ok, old_artifact_id} = Current.BlobStore.put("defmodule Stub do\n")
    {:ok, new_artifact_id} = Current.BlobStore.put("defmodule Stub do\n  def ok, do: true\n")

    contents = "defmodule Replacement do\nend\n"
    {:ok, write_file_contents_artifact_id} = Current.BlobStore.put(contents)

    intents = [
      %Intent.EditFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: patch_path,
        old_artifact_id: old_artifact_id,
        new_artifact_id: new_artifact_id
      },
      %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: already_existing_path,
        contents_artifact_id: write_file_contents_artifact_id
      },
      %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: proposal_id,
        cmd: "echo",
        args: ["this should never run"]
      }
    ]

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: intents,
       justification: "Second effect fails for request: #{inspect(req.input)}",
       claims: [],
       dependencies: []
     }}
  end
end
