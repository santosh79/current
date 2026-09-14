defmodule Current.EventCommitter do
  use GenServer
  require Logger

  alias Current.Consensus.Commit
  alias Current.EventStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {consensus_opts, gen_opts} = Keyword.split(opts, [:consensus])
    GenServer.start_link(__MODULE__, consensus_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :consensus) do
      nil ->
        :ok

      consensus ->
        :ok = Current.Consensus.SingleNodeServer.subscribe(consensus, self())
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:consensus_confirmed, %Commit{events: events} = commit},
        state
      ) do
    Enum.each(events, fn event ->
      case EventStore.append(event) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to append consensus-confirmed event #{event.id}: #{inspect(reason)} \t commit index: #{commit.index}"
          )
      end
    end)

    {:noreply, state}
  end
end
