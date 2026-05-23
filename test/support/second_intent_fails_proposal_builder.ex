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
    path = Path.join(dir, "stub.ex")
    :ok = File.write!(path, "defmodule Stub do\nend\n")

    good_diff = """
    --- a/stub.ex
    +++ b/stub.ex
    @@ -1,2 +1,3 @@
     defmodule Stub do
    +  def ok, do: true
     end
    """

    missing_file_path = "/tmp/current_missing_file_#{System.unique_integer([:positive])}.ex"

    missing_file_path_intent = %Intent.ReadFile{
      id: Id.generate(),
      proposal_id: proposal_id,
      path: missing_file_path
    }

    intents = [
      %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: path,
        diff: good_diff
      },
      missing_file_path_intent,
      %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: proposal_id,
        cmd: "echo",
        args: ["hello"]
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
