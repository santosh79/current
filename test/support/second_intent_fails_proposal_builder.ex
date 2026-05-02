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

    bad_diff = """
    --- a/stub.ex
    +++ b/stub.ex
    @@ -1,2 +1,3 @@
     defmodule WrongModule do
    +  def bad, do: true
     end
    """

    intents = [
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :file_patch,
        payload: %{path: path, diff: good_diff}
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :file_patch,
        payload: %{path: path, diff: bad_diff}
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
