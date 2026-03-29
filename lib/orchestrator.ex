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
  def notify_workflow_created(shepherd_pid, workflow_pid, task_id, workflow)
      when is_pid(shepherd_pid) and is_pid(workflow_pid) do
    send(shepherd_pid, {:workflow_created, workflow_pid, task_id, workflow})
    :ok
  end

  @spec notify_proposal_produced(
          pid(),
          pid(),
          Current.Id.t(),
          Current.Id.t(),
          Current.Proposal.t()
        ) :: :ok
  def notify_proposal_produced(shepherd_pid, workflow_pid, task_id, workflow_id, proposal)
      when is_pid(shepherd_pid) and is_pid(workflow_pid) do
    send(shepherd_pid, {:proposal_produced, workflow_pid, task_id, workflow_id, proposal})
    :ok
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:workflow_created, workflow_pid, task_id, workflow}, state) do
    notify_listeners(state.listeners, {:workflow_created, task_id, workflow})
    :ok = Current.Workflow.produce_proposal(workflow_pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_produced, _workflow_pid, task_id, workflow_id, proposal}, state) do
    notify_listeners(state.listeners, {:proposal_produced, task_id, workflow_id, proposal})
    {:noreply, state}
  end

  defp notify_listeners(listeners, message) do
    Enum.each(listeners, fn pid ->
      send(pid, message)
    end)

    :ok
  end
end
