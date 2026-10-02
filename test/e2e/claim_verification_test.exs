defmodule Current.E2E.ClaimVerificationTest do
  @moduledoc """
  A proposal's claims are checked against the evidence the applied
  effects produced. A claim that doesn't hold fails the workflow.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{EffectResult, Event, Intent}

  setup do
    use_proposal_builder(Current.ClaimProposalBuilder)
  end

  # Submits an apply-mode task, approves and applies its proposal, and
  # waits for the workflow to end. Returns the workflow's committed events.
  defp apply_to_end(input) do
    {task_id, workflow_id, proposal} = submit_and_await_valid_proposal(input: input)
    approve_and_apply(proposal)
    await_finished(workflow_id)

    {task_id, events(workflow_id)}
  end

  defp claim_results(events) do
    for %Event.EffectApplied{result: %EffectResult.Claim{} = claim} <- events, do: claim
  end

  test "a claim that holds lets the workflow complete" do
    {task_id, events} = apply_to_end("tests pass")

    assert [%EffectResult.Claim{verified: true}] = claim_results(events)
    assert {:ok, :completed} = Current.get_status(task_id)
    refute any?(events, Event.EffectFailed)
  end

  test "a claim that doesn't hold fails the workflow and keeps its evidence" do
    {task_id, events} = apply_to_end("tests fail")

    # The claim's result, with the evidence that disproved it, is recorded...
    assert [%EffectResult.Claim{verified: false, reason: reason, evidence: evidence}] =
             claim_results(events)

    assert reason == "command exited with 1, expected 0"
    assert evidence.condition == :exit_code_equals

    # ...and then fails the workflow, right after it.
    names = Enum.map(events, & &1.__struct__)

    claim_at =
      Enum.find_index(events, &match?(%Event.EffectApplied{intent: %Intent.Claim{}}, &1))

    assert Enum.at(names, claim_at + 1) == Event.EffectFailed
    assert List.last(names) == Event.WorkflowFailed

    assert %Event.EffectFailed{intent: %Intent.Claim{}, reason: failed_reason} =
             Enum.find(events, &match?(%Event.EffectFailed{}, &1))

    assert failed_reason == "claim not verified: command exited with 1, expected 0"

    assert {:ok, :failed} = Current.get_status(task_id)
    assert {:ok, workflow} = Current.get_workflow(task_id)
    assert workflow.error =~ "claim not verified"
  end

  test "nothing after a failed claim is applied" do
    {_task_id, events} = apply_to_end("tests fail")

    refute Enum.any?(events, &match?(%Event.EffectApplied{intent: %Intent.Report{}}, &1))
    refute any?(events, Event.EffectApplicationComplete)
    refute any?(events, Event.WorkflowCompleted)
  end
end
