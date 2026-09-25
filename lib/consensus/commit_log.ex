defmodule Current.Consensus.Log do
  @moduledoc """
  A durable, disk-backed commit log.

  Callers pass the registered name (or pid) of the instance they mean via
  `server` -- defaulting to `__MODULE__`, the application's singleton WAL --
  so tests can start an isolated instance under its own name and path instead
  of writing through the same disk_log the supervised SingleNodeServer uses.

  Startup is synchronous: this GenServer does not finish starting until the
  WAL has been opened and fully replayed into memory. Therefore, a successfully
  started Log process is ready to serve requests.
  """

  use GenServer

  alias Current.Consensus.Commit

  @type state :: %{
          disk_log: atom(),
          commits: %{optional(pos_integer()) => Commit.t()},
          events: %{optional(Current.Id.t()) => Current.Event.t()}
        }

  @spec path() :: String.t()
  def path do
    :current
    |> Application.fetch_env!(:data_dir)
    |> Path.expand()
    |> Path.join("consensus/commit_log")
  end

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    log_path = Keyword.get(opts, :path, path())

    GenServer.start_link(
      __MODULE__,
      {name, log_path},
      name: name
    )
  end

  @spec put(Commit.t(), GenServer.server()) :: :ok
  def put(%Commit{} = commit, server \\ __MODULE__) do
    GenServer.call(
      server,
      {:put, commit}
    )
  end

  @spec get(Current.Id.t(), GenServer.server()) ::
          {:ok, Current.Event.t()} | {:error, :not_found}
  def get(event_id, server \\ __MODULE__) do
    GenServer.call(
      server,
      {:get, event_id}
    )
  end

  @spec get_commit(pos_integer(), GenServer.server()) ::
          {:ok, Commit.t()} | {:error, :not_found}
  def get_commit(index, server \\ __MODULE__) do
    GenServer.call(
      server,
      {:get_commit, index}
    )
  end

  @spec complete_log(GenServer.server()) :: [Commit.t()]
  def complete_log(server \\ __MODULE__) do
    GenServer.call(
      server,
      :complete_log
    )
  end

  @spec head(GenServer.server()) ::
          {:ok, Commit.t()} | :empty
  def head(server \\ __MODULE__) do
    GenServer.call(
      server,
      :head
    )
  end

  ## Server

  @impl true
  def init({name, log_path}) do
    # Trapped so terminate/2 runs on shutdown and closes the disk_log
    # cleanly; otherwise every stop, even a graceful one, leaves it
    # needing a repair on the next open.
    Process.flag(:trap_exit, true)
    disk_log = disk_log_name(name)

    :ok =
      open_disk_log(
        disk_log,
        log_path
      )

    state =
      replay_from_disk(
        disk_log,
        %{
          disk_log: disk_log,
          commits: %{},
          events: %{}
        }
      )

    {:ok, state}
  end

  # Trapping exits turns a linked process's death (e.g. the disk_log)
  # into a message. Keep the old behaviour: die with it.
  @impl true
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    _ = :disk_log.close(state.disk_log)
    :ok
  end

  @impl true
  def handle_call(
        {:put, %Commit{} = commit},
        _from,
        state
      ) do
    :ok = :disk_log.log(state.disk_log, commit)
    :ok = :disk_log.sync(state.disk_log)
    new_state = apply_commit(state, commit)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get, event_id}, _from, state) do
    reply =
      case Map.fetch(state.events, event_id) do
        {:ok, event} -> {:ok, event}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_commit, index}, _from, state) do
    reply =
      case Map.fetch(state.commits, index) do
        {:ok, commit} -> {:ok, commit}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:complete_log, _from, state) do
    commits =
      state.commits
      |> Map.values()
      |> Enum.sort_by(& &1.index)

    {:reply, commits, state}
  end

  @impl true
  def handle_call(:head, _from, state) do
    reply =
      case state.commits do
        commits when map_size(commits) == 0 ->
          :empty

        commits ->
          {_index, commit} =
            Enum.max_by(
              commits,
              fn {index, _commit} ->
                index
              end
            )

          {:ok, commit}
      end

    {:reply, reply, state}
  end

  ## Internal

  # A distinct :disk_log needs a distinct registered atom per instance.
  # Two Log processes both opening Current.Consensus.Log.DiskLog would
  # collide at the disk_log layer even though they are separate GenServers.
  defp disk_log_name(name) do
    Module.concat(name, DiskLog)
  end

  defp open_disk_log(disk_log, log_path) do
    :ok = File.mkdir_p!(Path.dirname(log_path))

    args = [
      name: disk_log,
      file: String.to_charlist(log_path),
      type: :halt,
      format: :internal,
      size: :infinity
    ]

    case :disk_log.open(args) do
      {:ok, ^disk_log} ->
        :ok

      {:repaired, ^disk_log, _recovered, _badbytes} ->
        :ok

      {:error, reason} ->
        raise """
        Current.Consensus.Log failed to open its WAL at #{log_path}: \
        #{inspect(reason)}
        """
    end
  end

  defp replay_from_disk(disk_log, state, continuation \\ :start) do
    case :disk_log.chunk(disk_log, continuation) do
      :eof ->
        state

      {:error, reason} ->
        raise """
        Current.Consensus.Log failed to replay its WAL: \
        #{inspect(reason)}
        """

      {next_continuation, commits} ->
        new_state =
          Enum.reduce(
            commits,
            state,
            fn commit, acc ->
              apply_commit(
                acc,
                commit
              )
            end
          )

        replay_from_disk(
          disk_log,
          new_state,
          next_continuation
        )
    end
  end

  defp apply_commit(state, %Commit{} = commit) do
    events =
      Enum.reduce(commit.events, state.events, fn event, acc ->
        Map.put(acc, event.id, event)
      end)

    %{state | commits: Map.put(state.commits, commit.index, commit), events: events}
  end
end
