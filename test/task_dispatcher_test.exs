defmodule Current.TaskDispatcherTest do
  use ExUnit.Case, async: false

  describe "task dispatcher" do
    test "committed TaskCreated starts an orchestrator under WorkflowSupervisor" do
      before =
        DynamicSupervisor.count_children(Current.WorkflowSupervisor).active

      task_id = Current.Id.generate()
      now = DateTime.utc_now()

      event = %Current.Event.TaskCreated{
        id: Current.Id.generate(),
        task_id: task_id,
        input: "test task",
        context: %{},
        mode: :plan,
        project_dir: Current.TestTmp.dir(),
        submitted_at: now,
        timestamp: now
      }

      :ok =
        Current.TaskDispatcher.register_listener(
          task_id,
          self()
        )

      assert :ok =
               Current.EventStore.append(event)

      assert_receive {
        :workflow_created,
        %Current.Event.WorkflowCreated{
          task_id: ^task_id
        }
      }

      after_count =
        DynamicSupervisor.count_children(Current.WorkflowSupervisor).active

      assert after_count >= before + 1
    end
  end
end
