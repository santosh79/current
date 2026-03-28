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
  end
end
