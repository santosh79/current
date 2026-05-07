defmodule Current.MultiIntentProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "MultiIntentProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    diff =
      [
        "--- signup.ex",
        "+++ signup.ex",
        "@@ -1,2 +1,3 @@",
        " defmodule Signup do",
        "+  def validate_email(email), do: String.contains?(email, \"@\")",
        " end",
        ""
      ]
      |> Enum.join("\n")

    intents = [
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :file_patch,
        payload: %{
          path: get_file_path(),
          diff: diff
        }
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :write_file,
        payload: %{
          path: get_file_path(),
          contents: "...generated test contents..."
        }
      },
      %Intent{
        id: Id.generate(),
        proposal_id: proposal_id,
        type: :write_file,
        payload: %{
          path: get_file_path(),
          contents: "...MORE generated test contents..."
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

  defp get_file_path() do
    dir = Path.join(System.tmp_dir!(), "current_multi_#{System.unique_integer([:positive])}")
    :ok = File.mkdir_p!(dir)
    path = Path.join(dir, "signup.ex")
    File.write!(path, "defmodule Signup do\nend\n")
    path
  end
end
