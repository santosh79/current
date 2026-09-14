defmodule Current.WorkflowStore do
  use GenServer
  require Logger

  alias Current.{
    Event,
    EventStore,
    Workflow,
    WorkflowReducer
  }

  alias Current.EventStore.Entry

  @table __MODULE__

  @sync_interval_ms 1_000
  @sync_batch_size 100

  @type state :: %{
          last_position: non_neg_integer()
        }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(
      __MODULE__,
      opts,
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @spec all() :: [Workflow.t()]
  def all do
    :ok = sync()
    :ets.select(@table, [{{{:workflow, :_}, :"$1"}, [], [:"$1"]}])
  end

  @spec get(Current.Id.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get(workflow_id) do
    :ok = sync()

    lookup_workflow(workflow_id)
  end

  @spec get_by_task_id(Current.Id.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_by_task_id(task_id) do
    :ok = sync()

    case :ets.lookup(
           @table,
           {:task, task_id}
         ) do
      [{{:task, ^task_id}, workflow_id}] ->
        lookup_workflow(workflow_id)

      [] ->
        {:error, :not_found}
    end
  end

  @spec get_status_by_task_id(Current.Id.t()) ::
          {:ok, Workflow.status()} | {:error, :not_found}
  def get_status_by_task_id(task_id) do
    with {:ok, workflow} <-
           get_by_task_id(task_id) do
      {:ok, workflow.status}
    end
  end

  @spec sync() :: :ok
  def sync do
    GenServer.call(
      __MODULE__,
      :sync
    )
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(
      @table,
      [
        :named_table,
        :set,
        :protected,
        read_concurrency: true
      ]
    )

    :ok =
      Current.EventNotifier.subscribe(
        self(),
        :all
      )

    state = %{
      last_position: 0
    }

    # Build the projection once at startup.
    state =
      sync_to_latest(state)

    schedule_sync()

    {:ok, state}
  end

  ## Synchronous catch-up

  @impl true
  def handle_call(
        :sync,
        _from,
        state
      ) do
    state =
      sync_to_latest(state)

    {:reply, :ok, state}
  end

  ## EventStore notification

  @impl true
  def handle_info(
        {:event_committed, %Entry{} = entry},
        state
      ) do
    state =
      consume_committed_entry(
        entry,
        state
      )

    {:noreply, state}
  end

  ## Periodic catch-up

  @impl true
  def handle_info(
        :sync,
        state
      ) do
    state =
      sync_to_latest(state)

    schedule_sync()

    {:noreply, state}
  end

  @impl true
  def handle_info(
        _message,
        state
      ) do
    {:noreply, state}
  end

  ## Incremental synchronization

  defp sync_to_latest(state) do
    target_position =
      EventStore.latest_position()

    sync_through(
      target_position,
      state
    )
  end

  defp sync_through(
         target_position,
         %{last_position: last_position} = state
       )
       when last_position >= target_position do
    state
  end

  defp sync_through(
         target_position,
         state
       ) do
    {:ok, entries} =
      EventStore.entries_after(
        state.last_position,
        @sync_batch_size
      )

    entries =
      Enum.take_while(
        entries,
        fn entry ->
          entry.position <= target_position
        end
      )

    case entries do
      [] ->
        state

      entries ->
        state =
          Enum.reduce(
            entries,
            state,
            &project_entry/2
          )

        sync_through(
          target_position,
          state
        )
    end
  end

  ## Live EventStore notifications

  defp consume_committed_entry(
         %Entry{
           position: position
         },
         %{last_position: last_position} = state
       )
       when position <= last_position do
    # Already picked up by a previous catch-up.
    state
  end

  defp consume_committed_entry(
         %Entry{
           position: position
         } = entry,
         %{last_position: last_position} = state
       )
       when position == last_position + 1 do
    # Fast path: this is exactly the next committed event.
    project_entry(
      entry,
      state
    )
  end

  defp consume_committed_entry(
         %Entry{
           position: position
         },
         state
       ) do
    # We observed a gap. Rather than trusting notification order,
    # recover the missing entries from EventStore in canonical
    # position order.
    sync_through(
      position,
      state
    )
  end

  ## Projection

  defp project_entry(
         %Entry{
           position: position,
           event: event
         },
         state
       ) do
    project_event(event)

    %{
      state
      | last_position: position
    }
  end

  defp project_event(%Event.WorkflowCreated{} = event) do
    {:ok, workflow} =
      WorkflowReducer.apply_event(
        nil,
        event
      )

    put_workflow(workflow)
  end

  defp project_event(%{workflow_id: workflow_id} = event) do
    case lookup_workflow(workflow_id) do
      {:ok, workflow} ->
        {:ok, updated_workflow} =
          WorkflowReducer.apply_event(
            workflow,
            event
          )

        put_workflow(updated_workflow)

      {:error, :not_found} ->
        raise """
        WorkflowStore invariant violation:
        canonical event #{inspect(event.__struct__)}
        references unknown workflow #{workflow_id}
        """
    end
  end

  defp project_event(_event) do
    # TaskCreated and any future non-workflow events still advance
    # last_position, but don't affect the workflow projection.
    :ok
  end

  ## ETS

  defp put_workflow(%Workflow{} = workflow) do
    true =
      :ets.insert(
        @table,
        {
          {:workflow, workflow.id},
          workflow
        }
      )

    true =
      :ets.insert(
        @table,
        {
          {:task, workflow.task_id},
          workflow.id
        }
      )

    :ok
  end

  defp lookup_workflow(workflow_id) do
    case :ets.lookup(
           @table,
           {:workflow, workflow_id}
         ) do
      [
        {
          {:workflow, ^workflow_id},
          workflow
        }
      ] ->
        {:ok, workflow}

      [] ->
        {:error, :not_found}
    end
  end

  ## Timer

  defp schedule_sync do
    Process.send_after(
      self(),
      :sync,
      @sync_interval_ms
    )

    :ok
  end
end
