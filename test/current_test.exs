defmodule CurrentTest do
  use ExUnit.Case, async: false

  doctest Current

  alias Current.{Event, Proposal, Request}

  @receive_timeout 5_000

  defp request do
    %Request{
      input: "add email validation to signup flow",
      context: %{}
    }
  end

  defp submit_and_await_valid_proposal do
    {:ok, task_id} = Current.submit_task(request(), self())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
          workflow_id
      after
        @receive_timeout ->
          flunk("did not receive workflow_created")
      end

    proposal =
      receive do
        {:proposal_produced,
         %Event.ProposalProduced{workflow_id: ^workflow_id, proposal: proposal}} ->
          assert %Proposal{} = proposal
          proposal
      after
        @receive_timeout ->
          flunk("did not receive proposal_produced")
      end

    receive do
      {:proposal_validated,
       %Event.ProposalValidated{workflow_id: ^workflow_id, proposal: %Proposal{id: proposal_id}}} ->
        assert proposal_id == proposal.id
    after
      @receive_timeout ->
        flunk("did not receive proposal_validated")
    end

    {:ok, task_id, workflow_id, proposal}
  end

  describe "submit_task/2" do
    test "creates a workflow that is queryable through the public API" do
      {:ok, task_id} = Current.submit_task(request(), self())

      receive do
        {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
          assert {:ok, workflow} = Current.get_workflow(task_id)
          assert workflow.id == workflow_id
          assert workflow.task_id == task_id

          assert {:ok, status} = Current.get_status(task_id)
          assert status in [:created, :planning, :validating, :waiting_for_approval]
      after
        @receive_timeout ->
          flunk("did not receive workflow_created")
      end
    end
  end

  describe "get_status/1" do
    test "returns not_found for an unknown task id" do
      unknown_task_id =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      assert {:error, :not_found} = Current.get_status(unknown_task_id)
    end
  end

  describe "review_proposal/2" do
    test "returns not_found for an unknown proposal" do
      unknown_proposal_id =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      assert {:error, :not_found} =
               Current.review_proposal(
                 unknown_proposal_id,
                 {:approve, %{reviewed_by: :test_user}}
               )
    end

    test "approving a validated proposal completes the workflow" do
      {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{reviewed_by: :test_user}}
               )

      receive do
        {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive workflow_completed")
      end

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.id == workflow_id
      assert workflow.status == :completed
      assert workflow.proposal.id == proposal.id
      assert workflow.result != nil
    end

    test "rejecting a validated proposal leaves the workflow rejected" do
      {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:reject, %{reviewed_by: :test_user}}
               )

      receive do
        {:proposal_rejected, %Event.ProposalRejected{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive proposal_rejected")
      end

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.id == workflow_id
      assert workflow.status == :rejected
      assert workflow.proposal.id == proposal.id
      assert workflow.result == nil
      assert workflow.completed_at == nil

      refute_receive {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}},
                     200
    end
  end

  describe "workflow failure" do
    test "an invalid proposal fails the workflow" do
      :persistent_term.put(:proposal_builder, Current.FaultyProposalBuilder)

      on_exit(fn ->
        :persistent_term.put(:proposal_builder, Current.ProposalBuilder)
      end)

      {:ok, task_id} = Current.submit_task(request(), self())

      workflow_id =
        receive do
          {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
            workflow_id
        after
          @receive_timeout ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_validation_failed, %Event.ProposalValidationFailed{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive proposal_validation_failed")
      end

      receive do
        {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive workflow_failed")
      end

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.status == :failed
      assert workflow.error == "proposal validation failed"
      assert workflow.result == nil
    end
  end
end
