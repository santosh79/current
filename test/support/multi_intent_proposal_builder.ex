defmodule Current.MultiIntentProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "MultiIntentProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    intents = [
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :file_patch,
        payload: %{
          path: "lib/my_app/signup.ex",
          diff: "...diff for signup validation..."
        }
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :write_file,
        payload: %{
          path: "test/my_app/signup_test.exs",
          contents: "...generated test contents..."
        }
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :run_command,
        payload: %{
          command: "mix test test/my_app/signup_test.exs"
        }
      }
    ]

    proposal = %Proposal{
      id: proposal_id,
      workflow_id: workflow_id,
      intents: intents,
      justification: "Proposed changes for request: #{inspect(req.input)}",
      claims: [
        "signup flow validates email input",
        "test coverage is added for signup validation",
        "validation behavior is verified through command execution"
      ],
      dependencies: []
    }

    {:ok, proposal}
  end
end
