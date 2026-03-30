defmodule Current.WorkflowOrchestrator do
  use GenServer

  @type state :: %{
          listeners: [pid()]
        }

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    listeners = Keyword.get(opts, :listeners, [])
    GenServer.start_link(__MODULE__, %{listeners: listeners})
  end

  @spec notify_workflow_created(pid(), pid(), Current.Id.t(), Current.Workflow.t()) :: :ok
  def notify_workflow_created(orchestrator_pid, workflow_pid, task_id, workflow)
      when is_pid(orchestrator_pid) and is_pid(workflow_pid) do
    send(orchestrator_pid, {:workflow_created, workflow_pid, task_id, workflow})
    :ok
  end

  @spec notify_workflow_planning(pid(), pid(), Current.Id.t(), Current.Workflow.t()) :: :ok
  def notify_workflow_planning(orchestrator_pid, workflow_pid, task_id, workflow)
      when is_pid(orchestrator_pid) and is_pid(workflow_pid) do
    send(orchestrator_pid, {:workflow_planning, workflow_pid, task_id, workflow})
    :ok
  end

  @spec notify_proposal_produced(
          pid(),
          pid(),
          Current.Id.t(),
          Current.Workflow.t(),
          Current.Proposal.t()
        ) :: :ok
  def notify_proposal_produced(orchestrator_pid, workflow_pid, task_id, workflow, proposal)
      when is_pid(orchestrator_pid) do
    send(orchestrator_pid, {:proposal_produced, workflow_pid, task_id, workflow, proposal})
    :ok
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:workflow_created, workflow_pid, task_id, workflow}, state) do
    notify_listeners(state.listeners, {:workflow_created, task_id, workflow})
    GenServer.cast(workflow_pid, :start_planning)
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_produced, _workflow_pid, task_id, workflow, proposal}, state) do
    notify_listeners(state.listeners, {:proposal_produced, task_id, workflow, proposal})
    {:noreply, state}
  end

  @impl true
  def handle_info({:workflow_planning, workflow_pid, task_id, workflow}, state) do
    notify_listeners(state.listeners, {:workflow_planning, task_id, workflow})
    GenServer.cast(workflow_pid, :produce_proposal)
    {:noreply, state}
  end

  defp notify_listeners(listeners, message) do
    Enum.each(listeners, fn pid ->
      send(pid, message)
    end)

    :ok
  end
end
