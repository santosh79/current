defmodule Current.TaskStoreTest do
  use ExUnit.Case, async: false

  alias Current.{Request, Task, TaskStore}

  test "put stores a task built from the request and returns its id" do
    req = %Request{
      input: "add email validation",
      context: %{repo: "current"},
      mode: :plan
    }

    assert {:ok, task_id} = TaskStore.put(req)
    assert {:ok, task} = TaskStore.get(task_id)

    assert %Task{} = task
    assert task.id == task_id
    assert task.input == req.input
    assert task.context == req.context
    assert %DateTime{} = task.submitted_at
  end

  test "get returns not_found for an unknown task id" do
    unknown = "sha256:" <> String.duplicate("a", 64)
    assert {:error, :not_found} = TaskStore.get(unknown)
  end
end
