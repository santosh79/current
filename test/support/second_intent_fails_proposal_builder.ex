defmodule Current.SecondIntentFailsProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "SecondIntentFailsProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    dir =
      Path.join(
        System.tmp_dir!(),
        "current_second_intent_fails_#{System.unique_integer([:positive])}"
      )

    :ok = File.mkdir_p!(dir)

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

    intents = [
      %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: patch_path,
        diff: good_diff
      },
      %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: already_existing_path,
        contents: "defmodule Replacement do\nend\n"
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
