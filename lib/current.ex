defmodule Current do
  alias Current.{Request, Id, Workflow, TaskStore, Task}

  @spec submit_task(Current.Request.t(), pid()) ::
          {:ok, Current.Id.t()}
  def submit_task(%Request{} = req, caller_pid)
      when is_pid(caller_pid) do
    task_id = Id.generate()
    workflow_id = Id.generate()
    now = DateTime.utc_now()

    task = %Task{
      id: task_id,
      input: req.input,
      context: req.context,
      workflow_id: workflow_id,
      submitted_at: now
    }

    workflow = %Workflow{
      id: workflow_id,
      task_id: task_id,
      status: :created,
      proposal: nil,
      workflow_artifact: nil,
      events: [],
      started_at: nil,
      created_at: now,
      completed_at: nil,
      updated_at: now,
      error: nil
    }

    :ok = TaskStore.put(task)

    response = {:workflow_created, task_id, workflow}
    send(caller_pid, response)
    {:ok, task_id}
  end
end
