defmodule Current.WorkflowStoreTest do
  use ExUnit.Case, async: false

  alias Current.Id

  test "projects committed workflow events into ETS" do
    workflow_id = Id.generate()
    task_id = Id.generate()

    created = %Current.Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: task_id,
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    assert :ok = Current.EventNotifier.subscribe(self(), :workflow_created)
    assert :ok = Current.EventStore.append(created)
    assert :ok == Current.WorkflowStore.sync()

    # Event was sent from this process before this call, so this acts
    # as a mailbox barrier for WorkflowStore.
    :sys.get_state(Current.WorkflowStore)

    assert [
             {{:workflow, ^workflow_id}, workflow}
           ] =
             :ets.lookup(
               Current.WorkflowStore,
               {:workflow, workflow_id}
             )

    assert workflow.id == workflow_id
    assert workflow.task_id == task_id
    assert workflow.status == :created

    assert [
             {{:task, ^task_id}, ^workflow_id}
           ] =
             :ets.lookup(
               Current.WorkflowStore,
               {:task, task_id}
             )
  end

  test "advances its EventStore cursor incrementally" do
    before =
      :sys.get_state(Current.WorkflowStore).last_position

    workflow_id = Id.generate()
    task_id = Id.generate()

    created =
      %Current.Event.WorkflowCreated{
        id: Id.generate(),
        workflow_id: workflow_id,
        task_id: task_id,
        mode: :apply,
        timestamp: DateTime.utc_now()
      }

    assert :ok ==
             Current.EventStore.append(created)

    assert :ok ==
             Current.WorkflowStore.sync()

    after_sync =
      :sys.get_state(Current.WorkflowStore).last_position

    assert after_sync > before

    assert {:ok, workflow} =
             Current.WorkflowStore.get(workflow_id)

    assert workflow.id == workflow_id

    # A read with nothing new in EventStore does not move the cursor.
    assert :sys.get_state(Current.WorkflowStore).last_position >= after_sync
  end
end
