defmodule CurrentTest do
  use ExUnit.Case
  doctest Current

  alias Current.Task
  alias Current.Request
  alias Current.Workflow
  alias Current.Proposal

  describe "workflow creation" do
    test "submitting a task creates a workflow" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())
      assert :ok = Current.Id.validate(task_id)

      receive do
        {:workflow_created, ^task_id, workflow} ->
          {:ok, task} = Task.get(task_id)
          assert %Task{} = task
          assert task.input == req.input
          assert task.context == req.context
          assert task.submitted_at != nil

          assert %Workflow{} = workflow
          assert :ok = Current.Id.validate(workflow.id)
          assert workflow.task_id == task_id
          assert workflow.status == :created
          assert workflow.proposal == nil
          assert workflow.workflow_artifact == nil

          {:ok, fetched_workflow} = Current.get_workflow(task_id)
          assert fetched_workflow.id == workflow.id
      after
        1_000 ->
          flunk("did not receive workflow")
      end
    end

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

    ## Request submitted
    ## → task accepted
    ## → workflow created
    ## → proposal produced
    ## → caller receives proposal for review
    test "producing a proposal updates the workflow and emits it to the caller" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())
      assert :ok = Current.Id.validate(task_id)

      workflow =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            assert %Workflow{} = workflow
            assert :ok = Current.Id.validate(workflow.id)
            assert workflow.task_id == task_id
            assert workflow.status == :created
            workflow
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_produced, ^task_id, updated_workflow, proposal} ->
          assert updated_workflow.id == workflow.id

          assert %Proposal{} = proposal
          assert :ok = Current.Id.validate(proposal.id)
          assert proposal.workflow_id == workflow.id

          assert is_list(proposal.intents)
          assert length(proposal.intents) > 0

          assert is_binary(proposal.justification) or is_nil(proposal.justification)
          assert is_list(proposal.claims) or is_nil(proposal.claims)
          assert is_list(proposal.dependencies) or is_nil(proposal.dependencies)

          assert updated_workflow.id == workflow.id
          assert updated_workflow.proposal.id == proposal.id
          assert updated_workflow.status == :validating
      after
        1_000 ->
          flunk("did not receive proposal_produced")
      end
    end
  end

  ## Request submitted
  ## → workflow created (:created)
  ## → workflow starts planning (:planning)
  ## → proposal produced
  ## → workflow becomes :validating
  test "workflow emits planning before proposal production" do
    req = %Request{
      input: "add email validation to signup flow",
      context: %{}
    }

    {:ok, task_id} = Current.submit_task(req, self())

    workflow_id =
      receive do
        {:workflow_created, ^task_id, workflow} ->
          assert workflow.status == :created
          workflow.id
      after
        1_000 ->
          flunk("did not receive workflow_created")
      end

    receive do
      {:workflow_planning, ^task_id, workflow} ->
        assert workflow.id == workflow_id
        assert workflow.status == :planning
    after
      1_000 ->
        flunk("did not receive workflow_planning")
    end

    receive do
      {:proposal_produced, ^task_id, workflow, _proposal} ->
        assert workflow.status == :validating
    after
      1_000 ->
        flunk("did not receive proposal_produced")
    end
  end
end
