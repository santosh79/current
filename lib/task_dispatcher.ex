defmodule Current.TaskDispatcher do
  use GenServer
  require Logger

  alias Current.{EventStore, Id, TaskStore, Workflow, WorkflowStore}
  alias Current.Event.TaskCreated
  alias Current.EventStore.Entry

  @type state :: %{
          listeners: %{optional(Current.Id.t()) => MapSet.t(pid())},
          dispatched: MapSet.t(Current.Id.t())
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec register_listener(Current.Id.t(), pid()) :: :ok
  def register_listener(task_id, pid)
      when is_binary(task_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register_listener, task_id, pid})
  end

  @impl true
  def handle_call({:register_listener, task_id, pid}, _from, state) do
    listeners = Map.update(state.listeners, task_id, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | listeners: listeners}}
  end

  @impl true
  def init(_state) do
    :ok = Current.EventNotifier.subscribe(self(), :task_created)
    {:ok, %{listeners: %{}, dispatched: MapSet.new()}, {:continue, :resume_in_flight}}
  end

  # Runs once at boot, before any live notification is processed. Every
  # process it reads from (WorkflowStore, TaskStore, EventStore) is started
  # earlier in RuntimeSupervisor and has already rebuilt from the WAL.
  @impl true
  def handle_continue(:resume_in_flight, state) do
    workflows = WorkflowStore.all()

    workflows
    |> Enum.reject(&Workflow.terminal?/1)
    |> Enum.each(&resume_workflow/1)

    # Tasks whose TaskCreated committed but whose orchestrator never got as
    # far as WorkflowCreated: dispatch them as if the event just arrived.
    known_task_ids = MapSet.new(workflows, & &1.task_id)
    {:ok, entries} = EventStore.complete_log_entries()

    state =
      Enum.reduce(entries, state, fn
        %Entry{event: %TaskCreated{task_id: task_id} = event}, acc ->
          if MapSet.member?(known_task_ids, task_id), do: acc, else: dispatch(event, acc)

        _entry, acc ->
          acc
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:event_committed, %Entry{event: %TaskCreated{} = event}}, state) do
    {:noreply, dispatch(event, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(%TaskCreated{task_id: task_id} = event, state) do
    if MapSet.member?(state.dispatched, task_id) do
      state
    else
      listeners = state.listeners |> Map.get(task_id, MapSet.new()) |> MapSet.to_list()
      workflow_id = Id.generate()

      task = %Current.Task{
        id: event.task_id,
        input: event.input,
        context: event.context,
        mode: event.mode,
        project_dir: event.project_dir,
        model: event.model,
        submitted_at: event.submitted_at
      }

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Current.WorkflowSupervisor,
          {Current.WorkflowRunner, {workflow_id, task, listeners}}
        )

      %{
        state
        | listeners: Map.delete(state.listeners, task_id),
          dispatched: MapSet.put(state.dispatched, task_id)
      }
    end
  end

  defp resume_workflow(%Workflow{} = workflow) do
    case TaskStore.get(workflow.task_id) do
      {:ok, task} ->
        {:ok, _pid} =
          DynamicSupervisor.start_child(
            Current.WorkflowSupervisor,
            {Current.WorkflowRunner, {workflow.id, task, []}}
          )

      {:error, :not_found} ->
        Logger.warning(
          "not resuming workflow #{workflow.id} (#{workflow.status}): " <>
            "task #{workflow.task_id} not found"
        )
    end
  end
end
