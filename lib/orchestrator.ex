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

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:workflow_created, workflow_pid, %Current.Workflow{} = workflow}, state)
  when is_pid(workflow_pid) do
    :ok = create_event(:workflow_created, workflow)
    notify_listeners(state.listeners, {:workflow_created, workflow.task_id, workflow})
    GenServer.cast(workflow_pid, :start_planning)
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_produced, _workflow_pid, %Current.Workflow{} = workflow}, state) do
    :ok = create_event(:proposal_produced, workflow)

    notify_listeners(
      state.listeners,
      {:proposal_produced, workflow.task_id, workflow, workflow.proposal}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_production_started, workflow_pid, %Current.Workflow{} = workflow}, state)
  when is_pid(workflow_pid) do
    :ok = create_event(:proposal_production_started, workflow)

    notify_listeners(state.listeners, {:proposal_production_started, workflow.task_id, workflow})
    GenServer.cast(workflow_pid, :produce_proposal)
    {:noreply, state}
  end

  @impl true
  def handle_info({:review_proposal, workflow_pid, proposal_id, decision}, state) do
    GenServer.cast(workflow_pid, {:review_proposal, proposal_id, decision})
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_approved, _workflow_pid, %Current.Workflow{} = workflow}, state) do
    :ok = create_event(:proposal_approved, workflow)

    notify_listeners(state.listeners, {:proposal_approved, workflow.task_id, workflow})
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_rejected, _workflow_pid, %Current.Workflow{} = workflow}, state) do
    :ok = create_event(:proposal_rejected, workflow)

    notify_listeners(state.listeners, {:proposal_rejected, workflow.task_id, workflow})
    {:noreply, state}
  end

  defp notify_listeners(listeners, message) do
    Enum.each(listeners, fn pid ->
      send(pid, message)
    end)

    :ok
  end

  defp create_event(event_type, %Current.Workflow{} = workflow) do
    event = %Current.Event{
      id: Current.Id.generate(),
      workflow_id: workflow.id,
      type: event_type,
      data: %{
        task_id: workflow.task_id,
        workflow: workflow
      },
      timestamp: DateTime.utc_now()
    }

    :ok = Current.EventStore.append(event)
    :ok
  end
end
