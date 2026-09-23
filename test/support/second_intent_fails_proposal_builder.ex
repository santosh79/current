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

    good_diff = """
    --- a/stub.ex
    +++ b/stub.ex
    @@ -1,2 +1,3 @@
     defmodule Stub do
    +  def ok, do: true
     end
    """

    {:ok, good_diff_artifact_id} = Current.BlobStore.put(good_diff)
    contents = "defmodule Replacement do\nend\n"
    {:ok, write_file_contents_artifact_id} = Current.BlobStore.put(contents)

    intents = [
      %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: patch_path,
        diff_artifact_id: good_diff_artifact_id
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
