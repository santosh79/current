defmodule CurrentTest do
  use ExUnit.Case
  doctest Current

  alias Current.Request
  alias Current.Workflow
  alias Current.Proposal

  describe "workflow lifecycle" do
    test "get_status returns the workflow status for a submitted task" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      receive do
        {:workflow_created, ^task_id, _workflow} ->
          assert {:ok, status} = Current.get_status(task_id)
          assert status != nil
      after
        1_000 ->
          flunk("did not receive workflow")
      end
    end

    test "get_status returns not_found for an unknown task id" do
      unknown_task_id =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      assert {:error, :not_found} = Current.get_status(unknown_task_id)
    end

    ## orchestrator drives workflow transitions
    ##
    ## workflow_created
    ## → orchestrator triggers planning
    ## → workflow emits planning
    ## → orchestrator triggers proposal
    ## → workflow emits proposal
    test "orchestrator drives workflow transitions" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())
      assert :ok = Current.Id.validate(task_id)

      created_workflow =
        receive do
        {:workflow_created, ^task_id, workflow} ->
          assert %Workflow{} = workflow
          assert :ok = Current.Id.validate(workflow.id)
          assert workflow.task_id == task_id
          assert workflow.status == :created
          assert workflow.proposal == nil
          workflow
      after
        1_000 ->
          flunk("did not receive workflow_created")
      end

      planning_workflow =
        receive do
        {:proposal_production_started, ^task_id, workflow} ->
          assert %Workflow{} = workflow
          assert workflow.id == created_workflow.id
          assert workflow.task_id == task_id
          assert workflow.status == :planning
          assert workflow.proposal == nil
          assert workflow.started_at != nil
          workflow
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      receive do
        {:proposal_produced, ^task_id, workflow, proposal} ->
          assert %Workflow{} = workflow
          assert %Proposal{} = proposal

          assert workflow.id == created_workflow.id
          assert workflow.id == planning_workflow.id
          assert workflow.task_id == task_id
          assert workflow.status == :validating

          assert :ok = Current.Id.validate(proposal.id)
          assert proposal.workflow_id == workflow.id
          assert workflow.proposal.id == proposal.id

          assert is_list(proposal.intents)
          assert length(proposal.intents) > 0
      after
        1_000 ->
          flunk("did not receive proposal_produced")
      end
    end

    test "reviewing an unknown proposal returns not_found" do
      unknown_proposal_id =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      {:error, :not_found} =
        Current.review_proposal(unknown_proposal_id, {:approve, %{reviewed_by: :test_user}})
    end

    # submit task
    # receive workflow_created
    # receive proposal_production_started
    # receive proposal_produced
    # call Current.review_proposal/2 with approve
    # receive proposal_approved
    # fetch event log and assert ordered event types

    test "orchestrator logs approval lifecycle events in order" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
        {:workflow_created, ^task_id, workflow} ->
          workflow.id
      after
        1_000 ->
          flunk("did not receive workflow_created")
      end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
        {:proposal_produced, ^task_id, workflow, proposal} ->
          assert workflow.status == :validating
          proposal.id
      after
        1_000 ->
          flunk("did not receive proposal_produced")
      end

      assert :ok =
        Current.review_proposal(
          proposal_id,
          {:approve, %{reviewed_by: :test_user, note: "looks good"}}
        )

      receive do
        {:proposal_approved, ^task_id, workflow} ->
          assert workflow.status == :approved
      after
        1_000 ->
          flunk("did not receive proposal_approved")
      end

      events = Current.EventStore.list_by_workflow_id(workflow_id)

      assert Enum.map(events, & &1.type) == [
        :workflow_created,
        :proposal_production_started,
        :proposal_produced,
        :proposal_approved
      ]
    end


    # submit task
    # receive workflow_created
    # receive proposal_production_started
    # receive proposal_produced
    # call Current.review_proposal/2 with reject
    # receive proposal_rejected
    # fetch event log and assert ordered event types
    test "orchestrator logs rejection lifecycle events in order" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
        {:workflow_created, ^task_id, workflow} ->
          workflow.id
      after
        1_000 ->
          flunk("did not receive workflow_created")
      end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
        {:proposal_produced, ^task_id, workflow, proposal} ->
          assert workflow.status == :validating
          proposal.id
      after
        1_000 ->
          flunk("did not receive proposal_produced")
      end

      assert :ok =
        Current.review_proposal(
          proposal_id,
          {:reject, %{reviewed_by: :test_user, note: "proposal is not acceptable"}}
        )

      receive do
        {:proposal_rejected, ^task_id, workflow} ->
          assert workflow.status == :rejected
      after
        1_000 ->
          flunk("did not receive proposal_rejected")
      end

      events = Current.EventStore.list_by_workflow_id(workflow_id)

      assert Enum.map(events, & &1.type) == [
        :workflow_created,
        :proposal_production_started,
        :proposal_produced,
        :proposal_rejected
      ]
    end


  end
end
