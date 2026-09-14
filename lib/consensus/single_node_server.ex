defmodule Current.Consensus.SingleNodeServer do
  use GenServer

  alias Current.Consensus.{Commit, Log}

  @type state :: %{
          log: GenServer.server(),
          listeners: MapSet.t(pid())
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    listeners = Keyword.get(opts, :listeners, [])
    true = Enum.all?(listeners, &is_pid/1)
    log = Keyword.get(opts, :log, Log)
    state = %{log: log, listeners: MapSet.new(listeners)}
    {:ok, state}
  end

  @spec propose(GenServer.server(), [Current.Event.t()]) :: :ok | {:error, :invalid_events}
  def propose(_server, []) do
    {:error, :invalid_events}
  end

  def propose(server, events) when is_list(events) do
    case Enum.all?(events, &Current.Event.valid?/1) do
      false -> {:error, :invalid_events}
      true -> GenServer.call(server, {:propose, events})
    end
  end

  @spec propose(GenServer.server(), Current.Event.t()) :: :ok | {:error, :invalid_events}
  def propose(server, event) do
    propose(server, [event])
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid) when is_pid(pid) do
    GenServer.call(server, {:subscribe, pid})
  end

  @impl true
  def handle_call({:propose, events}, _from, state) when is_list(events) do
    # 1/ Grab the Log Head
    # 2/ Compute `previous_hash` and `index` for new commit based on Log Head
    # 3/ Create a new commit
    # 4/ Store in Log
    # 5/ Notify Listeners

    # 1/ Grab the Log Head
    log_head_commit =
      case Log.head(state.log) do
        :empty ->
          nil

        {:ok, log_head_commit} ->
          log_head_commit
      end

    {index, previous_hash} =
      case log_head_commit do
        nil -> {1, nil}
        _ -> {log_head_commit.index + 1, Commit.hash(log_head_commit)}
      end

    commit = Commit.new(index, events, previous_hash)

    :ok = Log.put(commit, state.log)

    Enum.each(state.listeners, fn listener ->
      send(listener, {:consensus_confirmed, commit})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | listeners: MapSet.put(state.listeners, pid)}}
  end
end
