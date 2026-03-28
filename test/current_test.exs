defmodule CurrentTest do
  use ExUnit.Case
  doctest Current

  alias Current.Task
  alias Current.Request
  alias Current.Workflow

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
          assert workflow.status in [:created, :planning]
          assert workflow.proposal == nil
          assert workflow.workflow_artifact == nil
      after
        1_000 ->
          flunk("did not receive workflow")
      end
    end

    test "get_workflow returns the workflow for a submitted task" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      receive do
        {:workflow_created, ^task_id, created_workflow} ->
          assert {:ok, fetched_workflow} = Current.get_workflow(task_id)
          assert fetched_workflow.id == created_workflow.id
          assert fetched_workflow.task_id == task_id

          assert fetched_workflow.status == created_workflow.status
          assert fetched_workflow.proposal == nil
          assert fetched_workflow.workflow_artifact == nil
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
        {:workflow_created, ^task_id, workflow} ->
          assert {:ok, status} = Current.get_status(task_id)
          assert status == workflow.status
          assert status in [:created, :planning]
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
  end
end
