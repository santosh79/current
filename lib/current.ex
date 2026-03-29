defmodule Current do
  use GenServer

  alias Current.{Request, Id, Workflow, WorkflowOrchestrator, WorkflowStore}

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

  @spec get_status(Current.Id.t()) ::
          {:ok, Current.Workflow.status()} | {:error, :not_found}
  def get_status(task_id) do
    GenServer.call(__MODULE__, {:get_status, task_id})
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:submit_task, %Request{} = req, caller_pid}, _from, state) do
    task_id = Id.generate()

    spawn_link(fn ->
      {:ok, orchestrator_pid} = WorkflowOrchestrator.start_link(listeners: [caller_pid])
      {:ok, _workflow_pid} = Workflow.create(task_id, req, orchestrator_pid)
    end)

    {:reply, {:ok, task_id}, state}
  end

  @impl true
  def handle_call({:get_workflow, task_id}, _from, state) do
    {:reply, WorkflowStore.get_by_task_id(task_id), state}
  end

  @impl true
  def handle_call({:get_status, task_id}, _from, state) do
    {:reply, WorkflowStore.get_status_by_task_id(task_id), state}
  end
end
