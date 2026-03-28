defmodule Current do
  use GenServer

  alias Current.{Request, Id, Workflow, TaskStore, Task}

  @type state :: %{}

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec submit_task(Current.Request.t(), pid()) ::
          {:ok, Current.Id.t()}
  def submit_task(%Request{} = req, caller_pid) when is_pid(caller_pid) do
    GenServer.call(__MODULE__, {:submit_task, req, caller_pid})
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:submit_task, %Request{} = req, caller_pid}, _from, state) do
    task_id = Id.generate()

    spawn_link(fn ->
      :ok = create_workflow(task_id, req, caller_pid)
    end)

    {:reply, {:ok, task_id}, state}
  end

  defp create_workflow(task_id, %Request{} = req, caller_pid) do
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
    send(caller_pid, {:workflow_created, task_id, workflow})
    :ok
  end
end
