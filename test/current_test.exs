defmodule CurrentTest do
  use ExUnit.Case
  doctest Current

  alias Current.Request
  alias Current.Workflow
  alias Current.Proposal

  describe "workflow creation" do
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
          {:workflow_planning, ^task_id, workflow} ->
            assert %Workflow{} = workflow
            assert workflow.id == created_workflow.id
            assert workflow.task_id == task_id
            assert workflow.status == :planning
            assert workflow.proposal == nil
            assert workflow.started_at != nil
            workflow
        after
          1_000 ->
            flunk("did not receive workflow_planning")
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
  end
end
