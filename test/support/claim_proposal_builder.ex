defmodule Current.ClaimProposalBuilder do
  @moduledoc """
  A test-only builder whose proposal runs a command and then claims it
  exited 0, followed by a Report.

  The command exits 1 when the request input contains "fail", so the
  same proposal shape covers both a claim that holds and one that
  doesn't.
  """

  @behaviour Current.ProposalBuilder

  alias Current.{Id, Intent, Proposal, Request}

  @impl true
  def build(%Request{} = req, workflow_id, _client_module, _timeout_ms, _project_dir) do
    unless Mix.env() == :test do
      raise "ClaimProposalBuilder must only be used in test environment"
    end

    proposal_id = Id.generate()
    exit_code = if String.contains?(req.input, "fail"), do: 1, else: 0

    command = %Intent.RunCommand{
      id: Id.generate(),
      proposal_id: proposal_id,
      cmd: "sh",
      args: ["-c", "exit #{exit_code}"]
    }

    claim = %Intent.Claim{
      id: Id.generate(),
      proposal_id: proposal_id,
      statement: "the test suite passes",
      evidence: %{source_intent_id: command.id, condition: :exit_code_equals, value: 0}
    }

    report = %Intent.Report{id: Id.generate(), proposal_id: proposal_id, summary: "done"}

    {:ok,
     %Proposal{
       id: proposal_id,
       workflow_id: workflow_id,
       intents: [command, claim, report],
       justification: "Run the tests for request: #{inspect(req.input)}",
       claims: [],
       dependencies: []
     }}
  end
end
