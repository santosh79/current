defmodule Current.Consensus.CommitLogSegmentsTest do
  # Every test runs its own isolated Log on its own directory. None of them
  # touch the application, its data_dir or the singleton WAL, so they could be
  # async -- they aren't only because a few capture logs.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Current.Consensus.{Commit, Log}

  setup do
    # Starting a Log that refuses to start sends its parent an exit signal.
    Process.flag(:trap_exit, true)

    dir = Path.join(System.tmp_dir!(), "commit_log_seg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, prefix: Path.join(dir, "commit_log")}
  end

  ## Rollover and recovery

  describe "rollover" do
    test "rolls over past the size limit, and a restart restores every commit", %{prefix: prefix} do
      log = start_log!(prefix, max_segment_bytes: 1_000)
      commits = put_chain(log, 20)

      assert length(Log.segments(log)) > 1
      stop_log(log)

      log = start_log!(prefix, max_segment_bytes: 1_000)
      assert Log.complete_log(log) == commits
      assert Log.head(log) == {:ok, List.last(commits)}

      # The chain carries on across the restart.
      more = put_chain(log, 5)
      stop_log(log)

      log = start_log!(prefix, max_segment_bytes: 1_000)
      assert Log.complete_log(log) == commits ++ more
    end

    test "a forced rollover starts a new segment and the old one is never written again",
         %{prefix: prefix} do
      log = start_log!(prefix)
      put_chain(log, 3)
      assert Log.segments(log) == [seg(prefix, 1)]

      assert :ok = Log.rollover(log)
      assert Log.segments(log) == [seg(prefix, 1), seg(prefix, 2)]

      closed_bytes = File.read!(seg(prefix, 1))
      put_chain(log, 3)

      assert File.read!(seg(prefix, 1)) == closed_bytes
      assert File.stat!(seg(prefix, 2)).size > 0
    end

    test "starting does not modify closed segments", %{prefix: prefix} do
      log = start_log!(prefix, max_segment_bytes: 1_000)
      put_chain(log, 12)
      stop_log(log)

      closed = Enum.drop(list_segment_files(prefix), -1)
      assert closed != []
      before = Map.new(closed, &{&1, File.read!(&1)})

      log = start_log!(prefix, max_segment_bytes: 1_000)
      put_chain(log, 1)
      stop_log(log)

      assert Map.new(closed, &{&1, File.read!(&1)}) == before
    end

    test "rollover never reuses a segment that already exists", %{prefix: prefix} do
      log = start_log!(prefix)
      put_chain(log, 2)

      # Appears after startup, so startup did not treat it as the active segment.
      sentinel = "not a log, and not to be touched"
      File.write!(seg(prefix, 2), sentinel)

      ref = Process.monitor(Process.whereis(log))
      assert {reason, _call} = catch_exit(Log.rollover(log))
      assert inspect(reason) =~ "already exists"
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      assert File.read!(seg(prefix, 2)) == sentinel
    end

    test "a commit acknowledged just before a failed rollover is recovered", %{prefix: prefix} do
      # One commit stays under the limit; the second crosses it.
      limit = 500
      log = start_log!(prefix, max_segment_bytes: limit)
      [first] = put_chain(log, 1)
      assert File.stat!(seg(prefix, 1)).size < limit

      # Block segment 2 *before* the put that will cross the limit, so the
      # rollover that follows that put has to fail.
      File.write!(seg(prefix, 2), "sentinel")
      ref = Process.monitor(Process.whereis(log))

      next = Commit.new(2, [event(2)], Commit.hash(first))
      assert :ok = Log.put(next, log)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000

      # The put had already been answered, and the commit is on disk.
      File.rm!(seg(prefix, 2))
      log = start_log!(prefix)
      assert Log.complete_log(log) == [first, next]
    end
  end

  ## put/2 refuses commits that do not extend the head

  describe "put/2" do
    test "refuses a commit that does not extend the head, and writes nothing", %{prefix: prefix} do
      log = start_log!(prefix)
      [one, two] = put_chain(log, 2)

      assert {:error, {:invalid_commit, {:index_gap, _}}} =
               Log.put(Commit.new(4, [event(4)], Commit.hash(two)), log)

      assert {:error, {:invalid_commit, {:duplicate_or_out_of_order, _}}} =
               Log.put(Commit.new(2, [event(2)], Commit.hash(one)), log)

      assert {:error, {:invalid_commit, {:duplicate_or_out_of_order, _}}} =
               Log.put(Commit.new(1, [event(1)], nil), log)

      assert {:error, {:invalid_commit, {:hash_mismatch, _}}} =
               Log.put(Commit.new(3, [event(3)], <<0::256>>), log)

      assert Log.head(log) == {:ok, two}
      stop_log(log)

      # Nothing refused was written, so the next start is clean.
      log = start_log!(prefix)
      assert Log.complete_log(log) == [one, two]
    end

    test "the first commit must be index 1 with no previous_hash", %{prefix: prefix} do
      log = start_log!(prefix)

      assert {:error, {:invalid_commit, {:bad_first_commit, _}}} =
               Log.put(Commit.new(2, [event(2)], nil), log)

      assert {:error, {:invalid_commit, {:bad_first_commit, _}}} =
               Log.put(Commit.new(1, [event(1)], <<1::256>>), log)

      assert Log.head(log) == :empty
    end
  end

  ## A log that cannot be vouched for is not started

  describe "startup refuses an invalid history" do
    test "a missing segment", %{prefix: prefix} do
      one = commits(1..2)
      two = commits(3..4, after: List.last(one))
      three = commits(5..6, after: List.last(two))
      write_segment(seg(prefix, 1), one)
      write_segment(seg(prefix, 2), two)
      write_segment(seg(prefix, 3), three)

      File.rm!(seg(prefix, 2))

      assert refuses_to_start(prefix) =~ "missing WAL segment"
    end

    test "a gap in commit indexes across segments", %{prefix: prefix} do
      one = commits(1..2)
      write_segment(seg(prefix, 1), one)
      write_segment(seg(prefix, 2), commits(4..5, after: List.last(one)))

      message = refuses_to_start(prefix)
      assert message =~ "index_gap"
      assert message =~ "missing"
    end

    test "a commit whose previous_hash does not match", %{prefix: prefix} do
      one = commits(1..2)
      write_segment(seg(prefix, 1), one)
      write_segment(seg(prefix, 2), [Commit.new(3, [event(3)], <<0::256>>)])

      assert refuses_to_start(prefix) =~ "hash_mismatch"
    end

    test "a repeated commit index", %{prefix: prefix} do
      one = commits(1..3)
      write_segment(seg(prefix, 1), one)
      write_segment(seg(prefix, 2), [Commit.new(3, [event(3)], Commit.hash(Enum.at(one, 1)))])

      assert refuses_to_start(prefix) =~ "duplicate_or_out_of_order"
    end

    test "a log that does not start at commit 1", %{prefix: prefix} do
      write_segment(seg(prefix, 1), [Commit.new(2, [event(2)], nil)])

      assert refuses_to_start(prefix) =~ "bad_first_commit"
    end

    test "a closed segment with a damaged tail", %{prefix: prefix} do
      one = commits(1..3)
      write_segment(seg(prefix, 1), one)
      write_segment(seg(prefix, 2), commits(4..5, after: List.last(one)))

      # Chop the end off the closed first segment. A read-only open does not
      # report a record lost this way; the chain check is what notices, because
      # segment 2 then no longer follows on.
      size = File.stat!(seg(prefix, 1)).size
      {:ok, file} = :file.open(String.to_charlist(seg(prefix, 1)), [:read, :write, :raw, :binary])
      {:ok, _} = :file.position(file, size - 5)
      :ok = :file.truncate(file)
      :ok = :file.close(file)

      assert refuses_to_start(prefix) =~ ~r/index_gap|corrupt byte/
    end

    test "a first segment that is not numbered 1", %{prefix: prefix} do
      one = commits(1..2)
      write_segment(seg(prefix, 5), one)
      write_segment(seg(prefix, 6), commits(3..4, after: List.last(one)))

      assert refuses_to_start(prefix) =~ "expected WAL segment 1"
    end
  end

  ## States an interrupted rollover can leave behind

  describe "recovering from an interrupted rollover" do
    test "old segment closed, new one not yet created", %{prefix: prefix} do
      one = commits(1..3)
      write_segment(seg(prefix, 1), one)

      log = start_log!(prefix)
      assert Log.head(log) == {:ok, List.last(one)}
      assert Log.segments(log) == [seg(prefix, 1)]

      [four] = put_chain(log, 1)
      stop_log(log)

      log = start_log!(prefix)
      assert Log.complete_log(log) == one ++ [four]
      assert Log.segments(log) == [seg(prefix, 1)]
    end

    test "new segment left empty (a zero-byte file)", %{prefix: prefix} do
      one = commits(1..3)
      write_segment(seg(prefix, 1), one)
      File.write!(seg(prefix, 2), "")

      log =
        capture_log_then(fn -> start_log!(prefix) end, fn logs ->
          assert logs =~ "removing empty trailing segment"
        end)

      assert Log.complete_log(log) == one
      assert Log.segments(log) == [seg(prefix, 1)]

      [four] = put_chain(log, 1)
      stop_log(log)

      log = start_log!(prefix)
      assert Log.complete_log(log) == one ++ [four]
    end

    test "new segment created but holding no commits yet", %{prefix: prefix} do
      one = commits(1..3)
      write_segment(seg(prefix, 1), one)
      write_segment(seg(prefix, 2), [])

      log = start_log!(prefix)
      assert Log.complete_log(log) == one
      assert Log.segments(log) == [seg(prefix, 1), seg(prefix, 2)]

      [four] = put_chain(log, 1)
      stop_log(log)

      log = start_log!(prefix)
      assert Log.complete_log(log) == one ++ [four]
      # The commit went to the new segment, not back into the closed one.
      assert length(Log.segments(log)) == 2
    end

    test "active segment that was not closed cleanly is repaired, with a warning",
         %{prefix: prefix} do
      one = commits(1..3)
      write_segment(seg(prefix, 1), one)
      two = commits(4..5, after: List.last(one))

      # A copy taken while the log is still open is what a crash leaves behind.
      disk_log = :"unclean_#{System.unique_integer([:positive])}"

      {:ok, ^disk_log} =
        :disk_log.open(
          name: disk_log,
          file: String.to_charlist(seg(prefix, 2)),
          type: :halt,
          format: :internal,
          size: :infinity
        )

      Enum.each(two, &(:ok = :disk_log.log(disk_log, &1)))
      :ok = :disk_log.sync(disk_log)
      unclean = seg(prefix, 2) <> ".copy"
      File.cp!(seg(prefix, 2), unclean)
      :ok = :disk_log.close(disk_log)
      File.rename!(unclean, seg(prefix, 2))

      log =
        capture_log_then(fn -> start_log!(prefix) end, fn logs ->
          assert logs =~ "repaired the active segment"
          assert logs =~ "2 commit(s) recovered"
        end)

      assert Log.complete_log(log) == one ++ two
    end
  end

  ## Upgrading from the single-file log

  describe "legacy single-file WAL" do
    test "is adopted as segment 1, and the whole history survives further writes",
         %{prefix: prefix} do
      legacy = commits(1..5)
      write_segment(prefix, legacy)

      log = start_log!(prefix)
      assert Log.segments(log) == [seg(prefix, 1)]
      refute File.exists?(prefix)
      assert Log.complete_log(log) == legacy
      assert Log.head(log) == {:ok, List.last(legacy)}

      more = put_chain(log, 3)
      stop_log(log)

      log = start_log!(prefix)
      assert Log.complete_log(log) == legacy ++ more
    end

    test "is refused when numbered segments exist beside it", %{prefix: prefix} do
      write_segment(prefix, commits(1..2))
      write_segment(seg(prefix, 1), commits(1..2))

      assert refuses_to_start(prefix) =~ "legacy WAL file"
    end
  end

  ## Options

  describe "options" do
    test "max_segment_bytes must be a positive integer", %{prefix: prefix} do
      for bad <- [0, -1, 1.5, "1000", nil] do
        assert_raise ArgumentError, ~r/max_segment_bytes/, fn ->
          Log.start_link(name: unique_name(), path: prefix, max_segment_bytes: bad)
        end
      end
    end

    test "on_rollover must be a function of one argument", %{prefix: prefix} do
      for bad <- [:not_a_function, fn -> :ok end, fn _a, _b -> :ok end] do
        assert_raise ArgumentError, ~r/on_rollover/, fn ->
          Log.start_link(name: unique_name(), path: prefix, on_rollover: bad)
        end
      end
    end
  end

  ## on_rollover

  describe "on_rollover" do
    test "is handed the path of the segment that was closed", %{prefix: prefix} do
      parent = self()
      log = start_log!(prefix, on_rollover: &send(parent, {:rolled_over, &1}))

      put_chain(log, 2)
      :ok = Log.rollover(log)

      assert_receive {:rolled_over, path}
      assert path == seg(prefix, 1)
    end

    test "a crashing hook does not take the log down", %{prefix: prefix} do
      log = start_log!(prefix, on_rollover: fn _path -> raise "boom" end)
      put_chain(log, 2)

      logs =
        capture_log(fn ->
          :ok = Log.rollover(log)
          # Give the hook's own process time to crash and be reported.
          Process.sleep(100)
        end)

      assert logs =~ "on_rollover hook failed"
      assert Process.alive?(Process.whereis(log))
      assert [_] = put_chain(log, 1)
    end
  end

  ## Helpers

  defp unique_name, do: Module.concat(__MODULE__, "Log#{System.unique_integer([:positive])}")

  # Started under the test's supervisor, so it is stopped (and its disk_log
  # closed) before the temp directory is removed.
  defp start_log!(prefix, opts \\ []) do
    name = unique_name()

    start_supervised!(%{
      id: name,
      start: {Log, :start_link, [[name: name, path: prefix] ++ opts]},
      restart: :temporary
    })

    name
  end

  defp stop_log(name), do: stop_supervised!(name)

  # Starts a Log directly and returns the message it refused to start with.
  defp refuses_to_start(prefix) do
    assert {:error, {%RuntimeError{message: message}, _stacktrace}} =
             Log.start_link(name: unique_name(), path: prefix)

    message
  end

  defp capture_log_then(fun, check) do
    parent = self()

    logs =
      capture_log(fn ->
        send(parent, {:result, fun.()})
      end)

    check.(logs)

    receive do
      {:result, result} -> result
    end
  end

  defp event(n), do: %{id: "event-#{n}", pad: String.duplicate("x", 200)}

  # Commits first..last, each linked to the one before. `after:` is the commit
  # (or nil, for the start of the log) the first one follows.
  defp commits(range, opts \\ []) do
    prev_hash =
      case Keyword.get(opts, :after) do
        nil -> nil
        %Commit{} = previous -> Commit.hash(previous)
      end

    range
    |> Enum.map_reduce(prev_hash, fn index, prev_hash ->
      commit = Commit.new(index, [event(index)], prev_hash)
      {commit, Commit.hash(commit)}
    end)
    |> elem(0)
  end

  # Appends `count` commits through the Log, each extending whatever the head is.
  defp put_chain(log, count) do
    for _ <- 1..count do
      {index, prev_hash} =
        case Log.head(log) do
          :empty -> {1, nil}
          {:ok, head} -> {head.index + 1, Commit.hash(head)}
        end

      commit = Commit.new(index, [event(index)], prev_hash)
      :ok = Log.put(commit, log)
      commit
    end
  end

  # Writes a segment file directly with :disk_log, the way the log itself
  # opens one (and the way the pre-segment version opened its single file).
  defp write_segment(path, commits) do
    name = :"writer_#{System.unique_integer([:positive])}"

    {:ok, ^name} =
      :disk_log.open(
        name: name,
        file: String.to_charlist(path),
        type: :halt,
        format: :internal,
        size: :infinity
      )

    Enum.each(commits, &(:ok = :disk_log.log(name, &1)))
    :ok = :disk_log.sync(name)
    :ok = :disk_log.close(name)
  end

  defp seg(prefix, n), do: prefix <> "." <> String.pad_leading(Integer.to_string(n), 8, "0")

  defp list_segment_files(prefix) do
    [dir, base] = [Path.dirname(prefix), Path.basename(prefix)]

    dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A#{Regex.escape(base)}\.\d{8}\z/, &1))
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
  end
end
