defmodule Current.ProposalStore do
  use GenServer

  alias Current.{
    Event,
    EventStore,
    Proposal
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
          {:ok, Proposal.t()} | {:error, :not_found}
  def get(proposal_id) do
    :ok = sync()

    lookup_proposal(proposal_id)
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
        :proposal_produced
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
    # ProposalProduced notifications may skip unrelated log positions.
    # Recover those positions from EventStore before applying this one.
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

  defp project_event(%Event.ProposalProduced{
         proposal: %Proposal{} = proposal
       }) do
    true =
      :ets.insert(
        @table,
        {
          proposal.id,
          proposal
        }
      )

    :ok
  end

  defp project_event(_event) do
    :ok
  end

  ## ETS

  defp lookup_proposal(proposal_id) do
    case :ets.lookup(
           @table,
           proposal_id
         ) do
      [{^proposal_id, proposal}] ->
        {:ok, proposal}

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
