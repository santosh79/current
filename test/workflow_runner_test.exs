defmodule Current.WorkflowRunnerTest do
  use ExUnit.Case, async: false

  alias Current.{Event, EventStore, Id, Task, WorkflowRunner, WorkflowStore}

  defp task(mode \\ :apply) do
    %Task{
      id: Id.generate(),
      input: "test",
      context: %{},
      mode: mode,
      # FakeProposalBuilder writes under the system tmp dir; the project
      # must contain it or validation (correctly) rejects the proposal.
      project_dir: Current.TestTmp.dir(),
      submitted_at: DateTime.utc_now()
    }
  end

  setup do
    Application.put_env(:current, :workflow_runner_max_attempts, 3)
    Application.put_env(:current, :workflow_runner_base_backoff_ms, 10)
    Application.put_env(:current, :workflow_runner_max_backoff_ms, 50)

    on_exit(fn ->
      Application.delete_env(:current, :workflow_runner_max_attempts)
      Application.delete_env(:current, :workflow_runner_base_backoff_ms)
      Application.delete_env(:current, :workflow_runner_max_backoff_ms)
    end)
  end

  test "a workflow that completes normally does not retry" do
    workflow_id = Id.generate()
    {:ok, pid} = WorkflowRunner.start_link({workflow_id, task(:plan), [self()]})
    ref = Process.monitor(pid)

    assert_receive {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}},
                   5_000

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "an orchestrator that crashes repeatedly abandons the workflow after max attempts" do
    workflow_id = Id.generate()

    :ok =
      Current.EventNotifier.subscribe(
        self(),
        workflow_id,
        :workflow_abandoned
      )

    {:ok, runner_pid} =
      WorkflowRunner.start_link({workflow_id, task(), [self()]})

    runner_ref = Process.monitor(runner_pid)

    crash_and_await_restart = fn ->
      %{orchestrator_pid: orchestrator_pid} = :sys.get_state(runner_pid)

      send(orchestrator_pid, :boom)
      await_new_orchestrator(runner_pid, orchestrator_pid)
    end

    # First two crashes consume retry attempts.
    crash_and_await_restart.()
    crash_and_await_restart.()

    # Third crash exhausts the retry budget.
    %{orchestrator_pid: orchestrator_pid} = :sys.get_state(runner_pid)
    send(orchestrator_pid, :boom)

    assert_receive {:event_committed,
                    %EventStore.Entry{
                      event:
                        %Event.WorkflowAbandoned{
                          workflow_id: ^workflow_id
                        } = event
                    }},
                   5_000

    assert event.reason =~ "crashed"
    assert event.reason =~ "giving up"

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}, 5_000

    assert {:ok, workflow} = WorkflowStore.get(workflow_id)
    assert workflow.status == :abandoned
  end

  defp await_new_orchestrator(runner_pid, old_pid, attempts \\ 100)

  defp await_new_orchestrator(_runner_pid, _old_pid, 0) do
    flunk("orchestrator did not restart in time")
  end

  defp await_new_orchestrator(runner_pid, old_pid, attempts) do
    case :sys.get_state(runner_pid) do
      %{orchestrator_pid: pid} when is_pid(pid) and pid != old_pid ->
        :ok

      _ ->
        Process.sleep(10)
        await_new_orchestrator(runner_pid, old_pid, attempts - 1)
    end
  end
end
