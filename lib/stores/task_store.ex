defmodule Current.TaskStore do
  use GenServer

  alias Current.{
    Event,
    EventStore,
    Task
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

  @spec get(Current.Id.t()) ::
          {:ok, Task.t()} | {:error, :not_found}
  def get(task_id) do
    :ok = sync()

    lookup_task(task_id)
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
        :task_created
      )

    state = %{
      last_position: 0
    }

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
    state
  end

  defp consume_committed_entry(
         %Entry{
           position: position
         } = entry,
         %{last_position: last_position} = state
       )
       when position == last_position + 1 do
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
    # A TaskCreated notification may legitimately jump over many
    # unrelated events because this store subscribes only to
    # :task_created. Catch up through the canonical EventStore log.
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

  defp project_event(%Event.TaskCreated{} = event) do
    task = %Task{
      id: event.task_id,
      input: event.input,
      context: event.context,
      mode: event.mode,
      project_dir: event.project_dir,
      model: event.model,
      timeout_ms: event.timeout_ms,
      submitted_at: event.submitted_at
    }

    true =
      :ets.insert(
        @table,
        {task.id, task}
      )

    :ok
  end

  defp project_event(_event) do
    :ok
  end

  ## ETS

  defp lookup_task(task_id) do
    case :ets.lookup(
           @table,
           task_id
         ) do
      [{^task_id, task}] ->
        {:ok, task}

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
