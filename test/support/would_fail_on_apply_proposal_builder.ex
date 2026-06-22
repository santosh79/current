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

    dir =
      Path.join(
        System.tmp_dir!(),
        "current_would_fail_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "existing.ex")

    # Create the file first — the WriteFile intent will fail because it already exists
    File.write!(path, "defmodule Existing do\nend\n")

    intent = %Intent.WriteFile{
      id: Id.generate(),
      proposal_id: proposal_id,
      path: path,
      contents: "defmodule Existing do\n  def ok, do: true\nend\n"
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
end
