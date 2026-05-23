defmodule Current.MultiIntentProposalBuilder do
  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "MultiIntentProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()
    dir = make_test_dir()

    patch_path = create_existing_signup_file(dir)
    generated_test_path = Path.join(dir, "signup_test.exs")
    generated_helper_path = Path.join(dir, "signup_helper.ex")

    intents = [
      %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: patch_path,
        diff: signup_diff()
      },
      %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: generated_test_path,
        contents: "defmodule SignupTest do\n  use ExUnit.Case\nend\n"
      },
      %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: generated_helper_path,
        contents: "defmodule SignupHelper do\n  def sample_email, do: \"test@example.com\"\nend\n"
      },
      %Intent.Glob{
        id: Id.generate(),
        proposal_id: proposal_id,
        pattern: "*.ex",
        base_dir: dir
      },
      %Intent.Grep{
        id: Id.generate(),
        proposal_id: proposal_id,
        pattern: "validate_email",
        paths: [patch_path]
      }
    ]

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: intents,
       justification: "Proposed changes for request: #{inspect(req.input)}",
       claims: [
         "signup flow validates email input",
         "test coverage is added for signup validation",
         "helper code is generated without overwriting existing files",
         "all .ex files in the module directory are discoverable",
         "validate_email is present in the patched signup module"
       ],
       dependencies: []
     }}
  end

  defp make_test_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "current_multi_#{System.unique_integer([:positive])}"
      )

    :ok = File.mkdir_p!(dir)
    dir
  end

  defp create_existing_signup_file(dir) do
    path = Path.join(dir, "signup.ex")
    :ok = File.write!(path, "defmodule Signup do\nend\n")
    path
  end

  defp signup_diff do
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
  end
end
