defmodule Current.WouldFailOnApplyProposalBuilder do
  @moduledoc """
  Produces a WriteFile intent to a path that already exists.

  IntentValidator does not validate WriteFile, so the proposal passes validation.
  In :apply mode the effect applicator rejects it ("file already exists").
  In :plan mode effects are never attempted, so the workflow completes as :planned.

  This is the canonical fixture for testing that plan mode completes proposals
  that would fail during effect application.
  """

  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id) do
    unless Mix.env() == :test do
      raise "WouldFailOnApplyProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()

    dir = make_test_dir()
    path = Path.join(dir, "existing.ex")

    # Create the file first — the WriteFile intent will fail because it already exists
    File.write!(path, "defmodule Existing do\nend\n")
    contents = "defmodule Existing do\n  def ok, do: true\nend\n"
    {:ok, content_artifact_id} = Current.BlobStore.put(contents)

    intent = %Intent.WriteFile{
      id: Id.generate(),
      proposal_id: proposal_id,
      path: path,
      contents_artifact_id: content_artifact_id
    }

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: [intent],
       justification: "Would fail on apply for: #{inspect(req.input)}",
       claims: [],
       dependencies: []
     }}
  end

  defp make_test_dir do
    suffix =
      Current.Id.generate()
      |> String.replace(":", "-")

    dir =
      Path.join(
        System.tmp_dir!(),
        "current_multi_#{suffix}"
      )

    :ok = File.mkdir_p!(dir)
    dir
  end
end
