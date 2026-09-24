defmodule Current.EventStore do
  @moduledoc """
  The canonical, validated projection of every event that has gone
  through consensus.

  Current.EventStore itself has no disk backing -- Current.Consensus.Log
  is the durable authority. So on every start (including the runtime
  rebuild that follows a Log crash, and a full application restart),
  EventStore reconstructs its state by replaying the entire durable
  commit history from Log through the same transition-validating logic
  append/1 uses live. Because that validation is a pure function of "the
  events already accepted for this workflow_id, in order," replaying the
  whole history in commit order reproduces exactly the same
  accepted/rejected outcome for every event as happened originally --
  including which events land in Current.Consensus.FailedEventsLog,
  which is rebuilt as a side effect of that same replay rather than
  needing any durability of its own.
  """

  use GenServer

  alias Current.Event
  alias Current.EventStore.Entry
  alias Current.WorkflowReducer

  @entries_table Current.EventStore.Entries
  @workflow_index Current.EventStore.WorkflowIndex

  @type state :: %{
          latest_position: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    @entries_table =
      :ets.new(@entries_table, [:named_table, :ordered_set, :protected, read_concurrency: true])

    @workflow_index =
      :ets.new(@workflow_index, [:named_table, :bag, :protected, read_concurrency: true])

    state = %{latest_position: 0}

    {:ok, rebuild_from_log(state)}
  end

  # ---------------------------------------------------------------------------
  # Append
  # ---------------------------------------------------------------------------
  @spec append(Current.Event.t()) ::
          :ok | {:error, :invalid_event} | {:error, term()}
  def append(event) do
    if Event.valid?(event) do
      case GenServer.call(__MODULE__, {:append, event}) do
        {:ok, entry} ->
          :ok = Current.EventNotifier.notify(entry)
          :ok

        {:error, reason} ->
          :ok = Current.Consensus.FailedEventsLog.put(event)
          {:error, reason}
      end
    else
      {:error, :invalid_event}
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  All events for a workflow stream, oldest first.
  """
  @spec list_by_workflow_id(Current.Id.t()) :: [Current.Event.t()]
  def list_by_workflow_id(workflow_id) do
    workflow_id
    |> list_entries_by_workflow_id()
    |> Enum.map(& &1.event)
  end

  @doc """
  All entries for a workflow stream -- events with their log positions --
  oldest first.
  """
  @spec list_entries_by_workflow_id(Current.Id.t()) :: [Entry.t()]
  def list_entries_by_workflow_id(workflow_id) do
    @workflow_index
    |> :ets.lookup(workflow_id)
    |> Enum.map(fn {^workflow_id, position} -> position end)
    |> Enum.sort()
    |> Enum.map(&entry_at!/1)
  end

  @doc """
  Returns the complete event log in insertion order, oldest first.
  """
  @spec complete_log_entries() :: {:ok, [Entry.t()]}
  def complete_log_entries do
    entries =
      @entries_table
      |> :ets.tab2list()
      |> Enum.map(fn {_position, entry} -> entry end)

    {:ok, entries}
  end

  @doc """
  Returns committed entries strictly after `position`, in commit order.
  """
  @spec entries_after(non_neg_integer(), pos_integer()) ::
          {:ok, [Entry.t()]}
  def entries_after(position, limit \\ 100)
      when is_integer(position) and
             position >= 0 and
             is_integer(limit) and
             limit > 0 do
    {:ok, take_entries_after(position, limit)}
  end

  @doc """
  Returns the position of the most recently committed entry.
  Returns 0 when the log is empty.
  """
  @spec latest_position() :: non_neg_integer()
  def latest_position do
    case :ets.last(@entries_table) do
      :"$end_of_table" -> 0
      position -> position
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:append, event}, _from, state) do
    {reply, new_state} = do_append(state, event)
    {:reply, reply, new_state}
  end

  def handle_call({:list_by_workflow_id, workflow_id}, _from, state) do
    result =
      state.entries
      |> Enum.filter(fn entry ->
        Map.get(entry.event, :workflow_id) == workflow_id
      end)
      |> Enum.sort_by(fn entry ->
        entry.position
      end)
      |> Enum.map(fn entry ->
        entry.event
      end)

    {:reply, result, state}
  end

  def handle_call(:complete_log_entries, _from, state) do
    entries = Enum.sort_by(state.entries, & &1.position)
    {:reply, {:ok, entries}, state}
  end

  def handle_call({:entries_after, position, limit}, _from, state) do
    entries =
      state.entries
      |> Enum.reverse()
      |> Enum.drop_while(fn entry ->
        entry.position <= position
      end)
      |> Enum.take(limit)

    {:reply, {:ok, entries}, state}
  end

  def handle_call(:latest_position, _from, state) do
    position =
      case state.entries do
        [%Entry{position: position} | _] -> position
        [] -> 0
      end

    {:reply, position, state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_append(state, event) do
    case apply_event(state, event) do
      {:ok, entry, new_state} ->
        {{:ok, entry}, new_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp rebuild_from_log(state) do
    Current.Consensus.Log.complete_log()
    |> Enum.flat_map(& &1.events)
    |> Enum.map(&Current.Event.Schema.upcast/1)
    |> Enum.reduce(state, fn event, state ->
      case apply_event(state, event) do
        {:ok, _entry, new_state} ->
          new_state

        {:error, _reason} ->
          :ok = Current.Consensus.FailedEventsLog.put(event)

          state
      end
    end)
  end

  defp apply_event(state, event) do
    case validate_workflow_transition(state, event) do
      :ok ->
        position = state.latest_position + 1

        entry = %Entry{
          position: position,
          event: event,
          inserted_at: DateTime.utc_now()
        }

        true = :ets.insert(@entries_table, {position, entry})
        maybe_index_workflow(event, position)

        {:ok, entry, %{state | latest_position: position}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_workflow_transition(_state, event) do
    case Map.get(event, :workflow_id) do
      nil ->
        :ok

      workflow_id ->
        existing_events = list_by_workflow_id(workflow_id)

        case WorkflowReducer.replay(existing_events ++ [event]) do
          {:ok, _workflow} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_index_workflow(event, position) do
    case Map.get(event, :workflow_id) do
      nil ->
        :ok

      workflow_id ->
        true = :ets.insert(@workflow_index, {workflow_id, position})
        :ok
    end
  end

  defp entry_at!(position) do
    case :ets.lookup(@entries_table, position) do
      [{^position, entry}] ->
        entry

      [] ->
        raise "EventStore workflow index refers to missing position #{position}"
    end
  end

  defp take_entries_after(position, limit) do
    case :ets.next(@entries_table, position) do
      :"$end_of_table" ->
        []

      next_position ->
        take_entries_from(next_position, limit, [])
    end
  end

  defp take_entries_from(_position, 0, acc) do
    Enum.reverse(acc)
  end

  defp take_entries_from(:"$end_of_table", _remaining, acc) do
    Enum.reverse(acc)
  end

  defp take_entries_from(position, remaining, acc) do
    entry = entry_at!(position)

    take_entries_from(
      :ets.next(@entries_table, position),
      remaining - 1,
      [entry | acc]
    )
  end
end

