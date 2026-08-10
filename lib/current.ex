defmodule Current do
  use GenServer

  alias Current.{
    Request,
    WorkflowOrchestrator,
    WorkflowReducer,
    WorkflowStore,
    RuntimeRegistry
  }

  @type decision ::
          {:approve, metadata :: map()}
          | {:reject, metadata :: map()}

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

  @doc """
  Rebuild a workflow purely from its event log.

  `get_workflow/1` reads the `WorkflowStore` projection; this bypasses the
  projection entirely and folds the ordered event stream through
  `Current.WorkflowReducer.replay/1`. Because every transition in the system is
  event-sourced, the two are always equal — this function exists to make that
  guarantee observable (and testable).
  """
  @spec replay_workflow(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found}
  def replay_workflow(workflow_id) do
    case Current.EventStore.list_by_workflow_id(workflow_id) do
      [] -> {:error, :not_found}
      events -> {:ok, WorkflowReducer.replay(events)}
    end
  end

  @spec review_proposal(Current.Id.t(), decision()) ::
          :ok | {:error, :not_found}
  def review_proposal(proposal_id, decision) do
    case WorkflowStore.get_by_proposal_id(proposal_id) do
      {:ok, workflow} ->
        case RuntimeRegistry.get(workflow.id) do
          {:ok, %{orchestrator_pid: o_pid}} ->
            send(o_pid, {:proposal_decision_made, proposal_id, decision})
            :ok

          _ ->
            {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:submit_task, %Request{} = req, caller_pid}, _from, state) do
    {:ok, task_id} = Current.TaskStore.put(req)

    event = %Current.Event.TaskCreated{
      id: Current.Id.generate(),
      task_id: task_id,
      mode: req.mode,
      timestamp: DateTime.utc_now()
    }

    :ok = Current.EventStore.append(event)

    {:ok, _orchestrator_pid} =
      WorkflowOrchestrator.start_link(listeners: [caller_pid], task_id: task_id, req: req)

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
