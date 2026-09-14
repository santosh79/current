defmodule Current.ConsensusIntegrationTest do
  @moduledoc """
  Like the unit test suite, each SingleNodeServer here gets its own
  isolated Log via dependency injection rather than writing through
  Current.Consensus.Log -- the application's singleton WAL is owned
  exclusively by the supervised Current.Consensus.SingleNodeServer.

  The isolated log runs under a fixed name for the same reason as the
  unit test suite: this module is async: false, so a fixed atom plus
  explicit teardown before the next test's setup is enough -- no need to
  keep minting fresh atoms per test.
  """

  use ExUnit.Case, async: false

  alias Current.{
    Event,
    EventStore,
    Id
  }

  alias Current.Consensus.{Log, SingleNodeServer}

  @receive_timeout 1_000
  @test_log Current.Consensus.TestLog

  defp start_isolated_log! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "current_wal_integration_test_#{System.unique_integer([:positive])}"
      )

    start_supervised!({Log, name: @test_log, path: Path.join(dir, "commit_log")})

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    @test_log
  end

  test "a proposed workflow event is eventually committed and delivered to EventNotifier subscribers" do
    log = start_isolated_log!()
    {:ok, committer_pid} = Current.EventCommitter.start_link()
    {:ok, pid} = SingleNodeServer.start_link(log: log, listeners: [committer_pid])
    workflow_id = Id.generate()

    :ok =
      Current.EventNotifier.subscribe(
        self(),
        workflow_id,
        :all
      )

    event = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    assert :ok =
             SingleNodeServer.propose(pid, event)

    assert_receive {
                     :event_committed,
                     %Current.EventStore.Entry{
                       event: ^event,
                       position: position
                     }
                   },
                   @receive_timeout

    assert position > 0
  end

  test "out-of-order workflow events are confirmed by consensus but not committed" do
    log = start_isolated_log!()

    {:ok, committer_pid} =
      Current.EventCommitter.start_link()

    {:ok, pid} =
      SingleNodeServer.start_link(log: log, listeners: [committer_pid])

    workflow_id = Id.generate()

    :ok =
      Current.EventNotifier.subscribe(
        self(),
        workflow_id,
        :all
      )

    workflow_created = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    effect_application_complete = %Event.EffectApplicationComplete{
      id: Id.generate(),
      workflow_id: workflow_id,
      intent_results: [],
      timestamp: DateTime.utc_now()
    }

    assert :ok =
             SingleNodeServer.propose(
               pid,
               workflow_created
             )

    assert_receive {
                     :event_committed,
                     %Current.EventStore.Entry{
                       event: ^workflow_created
                     }
                   },
                   @receive_timeout

    assert :ok =
             SingleNodeServer.propose(
               pid,
               effect_application_complete
             )

    refute_receive {
                     :event_committed,
                     %Current.EventStore.Entry{
                       event: ^effect_application_complete
                     }
                   },
                   @receive_timeout

    assert {:ok, confirmed_event} =
             Log.get(effect_application_complete.id, log)

    assert confirmed_event == effect_application_complete

    refute Enum.any?(
             EventStore.list_by_workflow_id(workflow_id),
             &(&1.id == effect_application_complete.id)
           )

    assert {:ok, failed_event} = Current.Consensus.FailedEventsLog.get(effect_application_complete.id)

    assert failed_event == effect_application_complete
  end
end
