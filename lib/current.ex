defmodule Current do
  use GenServer

  alias Current.{Request, Id, Workflow, WorkflowStore, TaskStore, Task}

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

  @spec get_workflow(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found}
  def get_workflow(task_id) do
    GenServer.call(__MODULE__, {:get_workflow, task_id})
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_workflow, task_id}, _from, state) do
    {:reply, WorkflowStore.get_by_task_id(task_id), state}
  end

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
    :ok = WorkflowStore.put(workflow)
    send(caller_pid, {:workflow_created, task_id, workflow})
    :ok
  end
end
