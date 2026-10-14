defmodule Current.Consensus.RolloverTest do
  # The one test that restarts the whole :current application. Everything
  # about the log itself -- rollover, validation, interrupted rollover,
  # migration -- is tested against isolated Log instances in
  # commit_log_segments_test.exs; this only checks that the stores built on
  # top of the log rebuild identically from many segments.
  #
  # It stops and starts the global application and swaps its data_dir, so it
  # must not run alongside other tests. ExUnit runs `async: false` modules
  # one at a time, after the async ones have finished.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Current.{Event, EventStore, Id, WorkflowStore}
  alias Current.Consensus
  alias Current.Consensus.{Commit, Log}
  alias Current.Error.ProposalProductionError

  # Small enough that a handful of commits fill a segment.
  @segment_bytes 4_096
  @workflows 30

  setup do
    original_dir = Application.fetch_env!(:current, :data_dir)
    original_bytes = Application.fetch_env(:current, :commit_log_segment_bytes)

    dir = Path.join(System.tmp_dir!(), "current_rollover_#{System.unique_integer([:positive])}")

    stop_app()
    Application.put_env(:current, :data_dir, dir)
    Application.put_env(:current, :commit_log_segment_bytes, @segment_bytes)
    start_app()

    on_exit(fn ->
      stop_app()
      Application.put_env(:current, :data_dir, original_dir)

      case original_bytes do
        {:ok, bytes} -> Application.put_env(:current, :commit_log_segment_bytes, bytes)
        :error -> Application.delete_env(:current, :commit_log_segment_bytes)
      end

      start_app()
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "the projection is identical after rolling over many segments and restarting" do
    total_events = Enum.sum(for _ <- 1..@workflows, do: record_failed_workflow())
    wait_for_projection(total_events)

    assert length(Log.segments()) > 1

    before_restart = snapshot()
    assert length(before_restart.events) == total_events
    assert_hash_chain(before_restart.commits)

    stop_app()
    start_app()

    assert length(Log.segments()) > 1
    assert snapshot() == before_restart
  end

  ## Helpers

  # Writes one workflow's whole life straight to consensus, ending in a
  # terminal state. No TaskCreated is proposed, so no orchestrator starts and
  # nothing else writes to the log while the test runs (and nothing needs
  # resuming after the restart). The first two events share one commit; the
  # rest get a commit each, so both batch shapes are covered. The long reason
  # string makes commits big enough to fill segments quickly.
  # Returns how many events it wrote.
  defp record_failed_workflow do
    workflow_id = Id.generate()
    now = DateTime.utc_now()

    created = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: Id.generate(),
      mode: :plan,
      timestamp: now
    }

    started = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: now
    }

    production_failed = %Event.ProposalProductionFailed{
      id: Id.generate(),
      workflow_id: workflow_id,
      error: %ProposalProductionError{stage: :timeout, reason: String.duplicate("x", 512)},
      timestamp: now
    }

    failed = %Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: workflow_id,
      reason: "proposal production failed",
      timestamp: now
    }

    :ok = Consensus.propose([created, started])
    :ok = Consensus.propose(production_failed)
    :ok = Consensus.propose(failed)
    4
  end

  # EventStore is fed asynchronously from the commit notifications.
  defp wait_for_projection(expected, attempts \\ 300) do
    cond do
      EventStore.latest_position() == expected ->
        :ok

      attempts == 0 ->
        flunk(
          "EventStore stuck at position #{EventStore.latest_position()}, expected #{expected}"
        )

      true ->
        Process.sleep(10)
        wait_for_projection(expected, attempts - 1)
    end
  end

  # Entries are compared by position and event only: inserted_at is stamped
  # when an entry is projected, so it legitimately differs after a rebuild.
  defp snapshot do
    :ok = WorkflowStore.sync()
    {:ok, entries} = EventStore.complete_log_entries()

    %{
      events: entries |> Enum.sort_by(& &1.position) |> Enum.map(&{&1.position, &1.event}),
      workflows: WorkflowStore.all() |> Enum.sort_by(& &1.id),
      commits: Log.complete_log()
    }
  end

  # The chain has to hold across segment boundaries.
  defp assert_hash_chain([first | _] = commits) do
    assert first.previous_hash == nil

    commits
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      assert b.index == a.index + 1
      assert b.previous_hash == Commit.hash(a)
    end)
  end

  defp stop_app do
    _ = Application.stop(:current)
    :ok
  end

  defp start_app do
    {:ok, _apps} = Application.ensure_all_started(:current)
    :ok
  end
end
