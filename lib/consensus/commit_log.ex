defmodule Current.Consensus.Log do
  @moduledoc """
  A durable, disk-backed commit log, stored as a sequence of segment files.

  Callers pass the registered name (or pid) of the instance they mean via
  `server` -- defaulting to `__MODULE__`, the application's singleton WAL --
  so tests can start an isolated instance under its own name and path instead
  of writing through the same disk_log the supervised SingleNodeServer uses.

  ## Guarantees

  `put/2` answers `:ok` only once the commit is written and synced, and only
  for a commit that extends the head: the next index, with `previous_hash`
  equal to `Commit.hash/1` of the head (index 1 and `nil` for the first
  commit). Anything else is answered with `{:error, {:invalid_commit, reason}}`
  and nothing is written, so a bad commit can never poison the next start.

  A log that starts has verified that what is on disk is one contiguous,
  hash-linked history:

    * segment numbers start at 1 and are consecutive;
    * the first commit has index 1 and no `previous_hash`;
    * every following commit has the next index and a `previous_hash` equal
      to the hash of its predecessor, across segment boundaries;
    * duplicate, repeated and out-of-order indexes are errors.

  Any violation raises from `init/1`, naming the file: the log refuses to
  start rather than serve a history it cannot vouch for.

  ## Segments

  The log is a series of `:halt` disk_logs named `<path>.00000001`,
  `<path>.00000002`, ... Only the highest-numbered segment is open for
  writing. Once it reaches `max_segment_bytes` (option `:max_segment_bytes`,
  or `config :current, :commit_log_segment_bytes`; default 64 MiB) the log
  rolls over: the active segment is closed and a new one is opened. This
  happens in this process, after the `put` that crossed the limit has been
  answered, so a successful `put/2` means "written and synced" whatever
  happens to the rollover afterwards. If the rollover itself fails the process
  crashes, and the acknowledged commit is recovered on the next start.

  Rollover refuses to roll onto a segment file that already exists. That check
  is not atomic: it assumes a single writer, i.e. that nothing else creates
  files in the WAL directory and that only one Log process writes a given
  path.

  Closed segments are immutable: they are opened read-only, never repaired,
  and corrupt bytes in one are an error. Only the active segment may be
  repaired by `:disk_log` after a crash, and a warning says how many terms
  were recovered and how many bytes discarded.

  A single file written by an earlier version (`<path>` itself) is renamed to
  segment 1 on first start.

  ## Options

  `:max_segment_bytes` must be a positive integer. `:on_rollover` is an
  optional function of one argument, called with the path of the segment that
  was just closed, in its own unlinked process. It is best-effort -- not
  retried, not ordered between segments, not remembered across a restart --
  and a crash in it never affects the log. It is handed a path, not a
  disk_log handle: only the process that opened a disk_log may close it.

  Startup is synchronous: a successfully started Log process has replayed
  every segment and is ready to serve requests.

  Rollover bounds file size, not memory or startup time: every commit is still
  held in memory and replayed from the first segment. Bounding that needs
  snapshots/checkpoints, a separate change.

  See `docs/commit_log.md` for why `:disk_log`'s `:wrap` and `:rotate` types
  are not used, and for a caveat about `Commit.hash/1`.
  """

  use GenServer

  require Logger

  alias Current.Consensus.Commit

  @default_segment_bytes 64 * 1024 * 1024
  @segment_digits 8

  @type segment :: {pos_integer(), Path.t()}

  @type state :: %{
          disk_log: atom(),
          prefix: Path.t(),
          segment_seq: pos_integer(),
          segment_path: Path.t(),
          max_segment_bytes: pos_integer(),
          on_rollover: (Path.t() -> any()) | nil,
          head: Commit.t() | nil,
          commits: %{optional(pos_integer()) => Commit.t()},
          events: %{optional(Current.Id.t()) => Current.Event.t()}
        }

  @doc "The path prefix; segment files are `<path>.NNNNNNNN`."
  @spec path() :: String.t()
  def path do
    :current
    |> Application.fetch_env!(:data_dir)
    |> Path.expand()
    |> Path.join("consensus/commit_log")
  end

  ## Client API

  @doc """
  Starts the log. Options: `:name`, `:path`, `:max_segment_bytes` (a positive
  integer), `:on_rollover` (a 1-arity function). Raises `ArgumentError` for an
  invalid option.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    log_path = Keyword.get_lazy(opts, :path, &path/0)

    max_segment_bytes =
      Keyword.get_lazy(opts, :max_segment_bytes, fn ->
        Application.get_env(:current, :commit_log_segment_bytes, @default_segment_bytes)
      end)

    on_rollover = Keyword.get(opts, :on_rollover)

    validate_max_segment_bytes!(max_segment_bytes)
    validate_on_rollover!(on_rollover)

    GenServer.start_link(
      __MODULE__,
      {name, log_path, max_segment_bytes, on_rollover},
      name: name
    )
  end

  @doc """
  Durably appends `commit`. The commit must extend the current head: the next
  index, with `previous_hash` equal to the head's hash (index 1 and `nil` for
  the first commit). Anything else is refused, and nothing is written.
  """
  @spec put(Commit.t(), GenServer.server()) :: :ok | {:error, {:invalid_commit, term()}}
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

  @doc "Forces a rollover now, regardless of the active segment's size."
  @spec rollover(GenServer.server()) :: :ok
  def rollover(server \\ __MODULE__) do
    GenServer.call(server, :rollover)
  end

  @doc "Segment files in order, oldest first. The last one is active."
  @spec segments(GenServer.server()) :: [Path.t()]
  def segments(server \\ __MODULE__) do
    GenServer.call(server, :segments)
  end

  ## Server

  @impl true
  def init({name, log_path, max_segment_bytes, on_rollover}) do
    # Trapped so terminate/2 runs on shutdown and closes the disk_log
    # cleanly; otherwise every stop, even a graceful one, leaves it
    # needing a repair on the next open.
    Process.flag(:trap_exit, true)
    disk_log = disk_log_name(name)

    File.mkdir_p!(Path.dirname(log_path))
    migrate_single_file!(log_path)

    segments =
      log_path
      |> list_segments()
      |> drop_empty_trailing_segment()
      |> validate_segments!(log_path)

    {closed, {active_seq, active_path}} =
      case segments do
        [] -> {[], {1, segment_path(log_path, 1)}}
        segments -> {Enum.drop(segments, -1), List.last(segments)}
      end

    state = %{
      disk_log: disk_log,
      prefix: log_path,
      segment_seq: active_seq,
      segment_path: active_path,
      max_segment_bytes: max_segment_bytes,
      on_rollover: on_rollover,
      head: nil,
      commits: %{},
      events: %{}
    }

    # Closed segments first, in order, then the active one -- which stays open.
    state = Enum.reduce(closed, state, fn {_seq, path}, acc -> replay_closed(path, acc) end)

    :ok = open_disk_log(disk_log, active_path, :read_write)

    {:ok, replay_from_disk(disk_log, state, active_path)}
  end

  # Trapping exits turns a linked process's death (e.g. the disk_log)
  # into a message. Keep the old behaviour: die with it.
  @impl true
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

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
    case check_successor(state.head, commit) do
      :ok ->
        :ok = :disk_log.log(state.disk_log, commit)
        :ok = :disk_log.sync(state.disk_log)
        new_state = apply_commit(state, commit)

        # Answer first; rotate (if due) before the next message is handled.
        {:reply, :ok, new_state, {:continue, :maybe_rollover}}

      {:error, reason} ->
        {:reply, {:error, {:invalid_commit, reason}}, state}
    end
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
      case state.head do
        nil -> :empty
        %Commit{} = head -> {:ok, head}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:rollover, _from, state) do
    {:reply, :ok, do_rollover(state)}
  end

  @impl true
  def handle_call(:segments, _from, state) do
    {:reply, Enum.map(list_segments(state.prefix), fn {_seq, path} -> path end), state}
  end

  @impl true
  def handle_continue(:maybe_rollover, state) do
    {:noreply, maybe_rollover(state)}
  end

  ## Commit chain

  # What a commit must look like to be appended after `head` (nil: the log is
  # empty). Used both before a live write and while replaying, so a commit
  # that could not be written live could not be replayed either.
  @spec check_successor(Commit.t() | nil, term()) :: :ok | {:error, term()}
  defp check_successor(nil, %Commit{index: 1, previous_hash: nil}), do: :ok

  defp check_successor(nil, %Commit{index: index, previous_hash: previous_hash}) do
    {:error,
     {:bad_first_commit,
      "the first commit must have index 1 and no previous_hash, " <>
        "got index #{inspect(index)} and previous_hash #{inspect(previous_hash)}"}}
  end

  defp check_successor(%Commit{index: head_index} = head, %Commit{index: index} = commit) do
    expected = head_index + 1

    cond do
      index == expected ->
        if commit.previous_hash == Commit.hash(head),
          do: :ok,
          else:
            {:error,
             {:hash_mismatch,
              "commit #{index} does not link to commit #{head_index}: its previous_hash " <>
                "is not the hash of the commit before it"}}

      index <= head_index ->
        {:error,
         {:duplicate_or_out_of_order,
          "commit index #{inspect(index)} does not follow #{head_index}: " <>
            "expected #{expected} (a repeated or out-of-order commit)"}}

      true ->
        {:error,
         {:index_gap,
          "commit index #{inspect(index)} does not follow #{head_index}: expected #{expected} " <>
            "(commits #{expected}..#{index - 1} are missing)"}}
    end
  end

  defp check_successor(_head, other) do
    {:error, {:not_a_commit, "expected a Commit, got #{inspect(other, limit: 5)}"}}
  end

  ## Rollover

  defp maybe_rollover(state) do
    case File.stat(state.segment_path) do
      {:ok, %File.Stat{size: size}} when size >= state.max_segment_bytes ->
        do_rollover(state)

      _ ->
        state
    end
  end

  # Every put syncs, so the segment being closed is already durable.
  # Closing then opening under the same disk_log name keeps `state.disk_log`
  # valid for every later call.
  #
  # The next file is checked *before* anything is closed. :disk_log would
  # happily open (and append to) a file that is already there, so this check is
  # what stops rollover reusing a segment -- but it is check-then-open, not
  # atomic, and relies on this process being the only writer. :disk_log cannot
  # open a file we created ourselves (an empty file is not a log to it), so
  # exclusive creation is not available.
  #
  # Order matters for crash safety: the old segment is closed (cleanly) before
  # the new one is created, so a crash leaves every segment but the highest
  # cleanly closed:
  #
  #   * before the close, or after it but before the new file exists: the old
  #     segment is the highest and is reopened as the active one;
  #   * while :disk_log creates the new file: the file may be left empty (our
  #     inference from how :disk_log behaves; not reproduced by killing the VM
  #     mid-rollover). An empty highest segment holds no commits and is removed
  #     on startup, see drop_empty_trailing_segment/1;
  #   * after the new file exists: it is the highest and becomes the active one.
  #
  # The tests cover each of those states, built as files on disk.
  defp do_rollover(state) do
    closed_path = state.segment_path
    next_seq = state.segment_seq + 1
    next_path = segment_path(state.prefix, next_seq)

    if File.exists?(next_path) do
      raise "Current.Consensus.Log refusing to roll over: #{next_path} already exists " <>
              "and would be reused"
    end

    :ok = :disk_log.close(state.disk_log)
    :ok = open_disk_log(state.disk_log, next_path, :read_write)

    notify_rollover(state.on_rollover, closed_path)

    %{state | segment_seq: next_seq, segment_path: next_path}
  end

  defp notify_rollover(nil, _closed_path), do: :ok

  defp notify_rollover(hook, closed_path) when is_function(hook, 1) do
    # Not linked: a slow or crashing hook must not touch the log.
    {:ok, _pid} =
      Task.start(fn ->
        try do
          hook.(closed_path)
        catch
          kind, reason ->
            Logger.error(
              "commit log on_rollover hook failed for #{closed_path}: " <>
                Exception.format_banner(kind, reason)
            )
        end
      end)

    :ok
  end

  ## Options

  defp validate_max_segment_bytes!(bytes) when is_integer(bytes) and bytes > 0, do: :ok

  defp validate_max_segment_bytes!(other) do
    raise ArgumentError,
          "commit log max_segment_bytes must be a positive integer, got: #{inspect(other)}"
  end

  defp validate_on_rollover!(nil), do: :ok
  defp validate_on_rollover!(hook) when is_function(hook, 1), do: :ok

  defp validate_on_rollover!(other) do
    raise ArgumentError,
          "commit log on_rollover must be nil or a function of one argument, got: #{inspect(other)}"
  end

  ## Segment files

  defp segment_path(prefix, seq) do
    prefix <> "." <> String.pad_leading(Integer.to_string(seq), @segment_digits, "0")
  end

  # Sorted by sequence number. Matches only `<basename>.<digits>`, so a
  # `.tmp` or other sibling is never mistaken for a segment.
  defp list_segments(prefix) do
    dir = Path.dirname(prefix)
    base = Path.basename(prefix)
    pattern = ~r/\A#{Regex.escape(base)}\.(\d{#{@segment_digits}})\z/

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          case Regex.run(pattern, name) do
            [_, digits] -> [{String.to_integer(digits), Path.join(dir, name)}]
            nil -> []
          end
        end)
        |> Enum.sort()

      {:error, :enoent} ->
        []
    end
  end

  # A crash while :disk_log was creating the newest segment may leave it empty
  # (see do_rollover/1), and an empty file is not a log :disk_log can open. It
  # holds no commits, so removing it loses nothing. Only the highest segment
  # can be in this state: every earlier one was closed before the next was
  # created. An empty segment anywhere else is not touched, and fails startup.
  defp drop_empty_trailing_segment([]), do: []

  defp drop_empty_trailing_segment(segments) do
    {seq, path} = List.last(segments)

    case File.stat(path) do
      {:ok, %File.Stat{size: 0}} ->
        Logger.warning(
          "Current.Consensus.Log removing empty trailing segment #{path} " <>
            "(segment #{seq}), left by an interrupted rollover"
        )

        File.rm!(path)
        Enum.drop(segments, -1)

      _ ->
        segments
    end
  end

  # Segments must be numbered 1, 2, 3, ... with none missing. Every start
  # replays the whole history from commit 1, which lives in segment 1, so a log
  # whose first segment is anything else is incomplete. (When checkpoints exist
  # and replay can begin partway through, this is the rule to relax.)
  defp validate_segments!([], _prefix), do: []

  defp validate_segments!([{first, _path} | _] = segments, prefix) do
    if first != 1 do
      raise """
      Current.Consensus.Log expected WAL segment 1 at #{segment_path(prefix, 1)}, \
      but the first segment is #{segment_path(prefix, first)}; \
      refusing to start with an incomplete log.
      """
    end

    segments
    |> Enum.map(fn {seq, _path} -> seq end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      if b != a + 1 do
        raise """
        Current.Consensus.Log found missing WAL segment(s) between \
        #{segment_path(prefix, a)} and #{segment_path(prefix, b)}; \
        refusing to start with an incomplete log.
        """
      end
    end)

    segments
  end

  # A log written before segmenting is one file at `prefix`. It becomes
  # segment 1. Both existing at once means something unexpected happened;
  # refuse rather than guess which is authoritative.
  defp migrate_single_file!(prefix) do
    cond do
      not File.regular?(prefix) ->
        :ok

      list_segments(prefix) == [] ->
        File.rename!(prefix, segment_path(prefix, 1))

      true ->
        raise """
        Current.Consensus.Log found both a legacy WAL file at #{prefix} and \
        numbered segments next to it; refusing to guess which is authoritative.
        """
    end
  end

  ## Internal

  # A distinct :disk_log needs a distinct registered atom per instance.
  # Two Log processes both opening Current.Consensus.Log.DiskLog would
  # collide at the disk_log layer even though they are separate GenServers.
  defp disk_log_name(name) do
    Module.concat(name, DiskLog)
  end

  # `mode` is :read_write for the active segment and :read_only for closed
  # ones, which are never to be modified -- not even by repair.
  defp open_disk_log(disk_log, log_path, mode) do
    args = [
      name: disk_log,
      file: String.to_charlist(log_path),
      type: :halt,
      format: :internal,
      size: :infinity,
      mode: mode
    ]

    case :disk_log.open(args) do
      {:ok, ^disk_log} ->
        :ok

      {:repaired, ^disk_log, {:recovered, recovered}, {:badbytes, badbytes}} ->
        Logger.warning(
          "Current.Consensus.Log repaired the active segment #{log_path} after an unclean " <>
            "shutdown: #{recovered} commit(s) recovered, #{badbytes} corrupt byte(s) discarded"
        )

        :ok

      {:error, reason} ->
        raise """
        Current.Consensus.Log failed to open its WAL at #{log_path}: \
        #{inspect(reason)}
        """
    end
  end

  # One reusable name, since segments are replayed one at a time.
  defp replay_closed(path, state) do
    replay_log = Module.concat(state.disk_log, Replay)

    :ok = open_disk_log(replay_log, path, :read_only)
    state = replay_from_disk(replay_log, state, path)
    :ok = :disk_log.close(replay_log)
    state
  end

  defp replay_from_disk(disk_log, state, path, continuation \\ :start) do
    case :disk_log.chunk(disk_log, continuation) do
      :eof ->
        state

      {:error, reason} ->
        raise """
        Current.Consensus.Log failed to replay #{path}: \
        #{inspect(reason)}
        """

      {_next_continuation, _commits, badbytes} ->
        raise """
        Current.Consensus.Log found #{inspect(badbytes)} corrupt byte(s) in #{path}; \
        refusing to start with a damaged log.
        """

      {next_continuation, commits} ->
        new_state = Enum.reduce(commits, state, &replay_commit!(&1, &2, path))

        replay_from_disk(disk_log, new_state, path, next_continuation)
    end
  end

  defp replay_commit!(commit, state, path) do
    case check_successor(state.head, commit) do
      :ok ->
        apply_commit(state, commit)

      {:error, {kind, message}} ->
        raise """
        Current.Consensus.Log refusing to start: invalid WAL in #{path} \
        (#{kind}): #{message}
        """
    end
  end

  defp apply_commit(state, %Commit{} = commit) do
    events =
      Enum.reduce(commit.events, state.events, fn event, acc ->
        Map.put(acc, event.id, event)
      end)

    %{
      state
      | head: commit,
        commits: Map.put(state.commits, commit.index, commit),
        events: events
    }
  end
end
