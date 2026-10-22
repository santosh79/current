defmodule Current.E2E.ReviewAndApplyTest do
  @moduledoc """
  An apply-mode workflow stops at approval. Approving and applying are
  separate steps (`Current.review_proposal/2`, `Current.apply_proposal/1`),
  and each is only accepted in the state it belongs to.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.Event
  alias Current.TestApproval

  @reviewer %{reviewed_by: :test_user}
  @unknown_proposal "sha256:" <> String.duplicate("b", 64)

  describe "review_proposal/2" do
    test "an unknown proposal is not found" do
      assert {:error, :not_found} =
               Current.review_proposal(@unknown_proposal, {:approve, @reviewer})
    end

    test "approving parks the workflow in :approved and applies nothing" do
      {task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok = Current.review_proposal(proposal.id, {:approve, @reviewer})
      await(:proposal_approved, workflow_id)

      refute_receive {:effect_applied, _}, 300
      refute_receive {:workflow_completed, _}, 0

      assert {:ok, :approved} = Current.get_status(task_id)
      refute any?(events(workflow_id), Event.EffectApplicationStarted)
    end

    test "rejecting leaves the workflow rejected, with no result" do
      {task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok = Current.review_proposal(proposal.id, {:reject, @reviewer})
      await(:proposal_rejected, workflow_id)

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.status == :rejected
      assert Current.Workflow.current_proposal(workflow).id == proposal.id
      assert workflow.result == nil
      assert workflow.completed_at == nil

      refute_receive {:proposal_approved, _}, 200
      refute_receive {:workflow_completed, _}, 0
    end

    test "a rejected proposal can't be reviewed again, and nothing is proposed for it" do
      {_task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok = Current.review_proposal(proposal.id, {:reject, @reviewer})
      await(:proposal_rejected, workflow_id)

      failed_before = length(Current.Consensus.FailedEventsLog.all())

      assert {:error, {:invalid_transition, :rejected, Event.ProposalApproved}} =
               Current.review_proposal(proposal.id, {:approve, @reviewer})

      assert {:error, {:invalid_transition, :rejected, Event.ProposalRejected}} =
               Current.review_proposal(proposal.id, {:reject, @reviewer})

      # Refused before anything was proposed, not rejected at commit time.
      assert length(Current.Consensus.FailedEventsLog.all()) == failed_before
    end

    test "a plan-mode proposal can't be reviewed" do
      workflow_id = submit!(mode: :plan) |> await_workflow_created()
      %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)
      await(:workflow_completed, workflow_id)

      assert {:error, {:invalid_transition, :planned, Event.ProposalApproved}} =
               Current.review_proposal(proposal.id, {:approve, @reviewer})
    end
  end

  describe "apply_proposal/1" do
    test "an unknown proposal is not found" do
      assert {:error, :not_found} = Current.apply_proposal(@unknown_proposal)
    end

    test "applying an approved proposal completes the workflow" do
      {task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      approve_and_apply(proposal)
      await(:workflow_completed, workflow_id)

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.id == workflow_id
      assert workflow.status == :completed
      assert Current.Workflow.current_proposal(workflow).id == proposal.id
      assert workflow.result != nil
    end

    test "a proposal waiting for approval can't be applied" do
      {task_id, _workflow_id, proposal} = submit_and_await_valid_proposal()

      assert {:error,
              {:invalid_transition, :waiting_for_approval, Event.EffectApplicationStarted}} =
               Current.apply_proposal(proposal.id)

      assert {:ok, :waiting_for_approval} = Current.get_status(task_id)
    end

    test "a rejected proposal can't be applied" do
      {_task_id, _workflow_id, proposal} = submit_and_await_valid_proposal()

      :ok = Current.review_proposal(proposal.id, {:reject, @reviewer})
      :ok = TestApproval.await_status(proposal.id, :rejected)

      assert {:error, {:invalid_transition, :rejected, Event.EffectApplicationStarted}} =
               Current.apply_proposal(proposal.id)
    end

    test "an approved proposal can't be reviewed again, and is applied only once" do
      {_task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      :ok = Current.review_proposal(proposal.id, {:approve, @reviewer})
      :ok = TestApproval.await_status(proposal.id, :approved)

      assert {:error, {:invalid_transition, :approved, Event.ProposalApproved}} =
               Current.review_proposal(proposal.id, {:approve, @reviewer})

      assert {:error, {:invalid_transition, :approved, Event.ProposalRejected}} =
               Current.review_proposal(proposal.id, {:reject, @reviewer})

      assert :ok = Current.apply_proposal(proposal.id)
      await(:workflow_completed, workflow_id)

      assert {:error, {:invalid_transition, :completed, Event.EffectApplicationStarted}} =
               Current.apply_proposal(proposal.id)

      assert Enum.count(events(workflow_id), &is_struct(&1, Event.EffectApplicationStarted)) == 1
    end
  end
end
