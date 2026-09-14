defmodule Current.Consensus.SingleNodeTest do
  @moduledoc """
  These SingleNodeServer instances are deliberately unsupervised, but they
  can no longer be allowed to write through the application's singleton
  WAL: two independent SingleNodeServers sharing one Consensus.Log both
  believe they own the next index, and the second commit at any given
  index silently clobbers the first in Log's in-memory map. Each test
  here therefore gets its own isolated Log instance via SingleNodeServer's
  injectable :log option, so this suite exercises SingleNodeServer's
  proposal/indexing behavior without touching Current.Consensus.Log.

  The test log runs under a fixed name (Current.Consensus.TestLog) rather
  than a freshly-generated atom per test -- atoms are never garbage
  collected, and since this module is async: false and each test stops
  its log in on_exit before the next test's setup starts a new one,
  uniqueness doesn't need to come from ever-new atom names.
  """

  use ExUnit.Case, async: false

  alias Current.{
    Event,
    Id
  }

  alias Current.Consensus.{
    Commit,
    Log,
    SingleNodeServer
  }

  @receive_timeout 1_000
  @test_log Current.Consensus.TestLog

  setup do
    dir =
      Path.join(System.tmp_dir!(), "current_wal_unit_test_#{System.unique_integer([:positive])}")

    start_supervised!({Log, name: @test_log, path: Path.join(dir, "commit_log")})

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    {:ok, pid} = SingleNodeServer.start_link(log: @test_log, listeners: [self()])
    %{pid: pid}
  end

  test "committed proposals receive monotonically increasing indexes", %{
    pid: pid
  } do
    workflow_id = Id.generate()

    first_batch = [
      %Event.WorkflowCreated{
        id: Id.generate(),
        workflow_id: workflow_id,
        task_id: Id.generate(),
        mode: :apply,
        timestamp: DateTime.utc_now()
      },
      %Event.ProposalProductionStarted{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      }
    ]

    second_batch = [
      %Event.WorkflowCompleted{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      }
    ]

    assert :ok = SingleNodeServer.propose(pid, first_batch)

    first_commit =
      receive do
        {:consensus_confirmed, %Commit{} = commit} ->
          commit
      after
        @receive_timeout ->
          flunk("did not receive first consensus confirmation")
      end

    assert first_commit.events == first_batch

    assert :ok = SingleNodeServer.propose(pid, second_batch)

    second_commit =
      receive do
        {:consensus_confirmed, %Commit{} = commit} ->
          commit
      after
        @receive_timeout ->
          flunk("did not receive second consensus confirmation")
      end

    assert second_commit.events == second_batch

    assert second_commit.index > first_commit.index
    assert second_commit.index == first_commit.index + 1
    assert second_commit.previous_hash == Current.Consensus.Commit.hash(first_commit)
  end

  test "rejects an empty proposal", %{pid: pid} do
    assert {:error, :invalid_events} =
             SingleNodeServer.propose(pid, [])
  end

  test "proposing something that is not a Event results in an error", %{pid: pid} do
    invalid_event = "an invalid event"
    assert {:error, :invalid_events} = SingleNodeServer.propose(pid, invalid_event)
    invalid_events = ["an invalid event"]
    assert {:error, :invalid_events} = SingleNodeServer.propose(pid, invalid_events)
  end
end
