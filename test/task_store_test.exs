defmodule Current.TaskStoreTest do
  use ExUnit.Case, async: false

  alias Current.{Event, EventStore, Id, Task}

  @table Current.TaskStore

  test "projects a committed TaskCreated event into ETS" do
    :ok = Current.EventNotifier.subscribe(self(), :task_created)

    task_id = Id.generate()
    now = DateTime.utc_now()

    event = %Event.TaskCreated{
      id: Id.generate(),
      task_id: task_id,
      input: "add email validation",
      context: %{repo: "current"},
      mode: :plan,
      submitted_at: now,
      timestamp: now
    }

    assert :ok = EventStore.append(event)

    assert_receive {
      :event_committed,
      %Current.EventStore.Entry{event: ^event}
    }

    # Ensure TaskStore has processed the event before reading ETS.
    :sys.get_state(Current.TaskStore)

    assert [{^task_id, task}] =
             :ets.lookup(@table, task_id)

    assert %Task{} = task
    assert task.id == task_id
    assert task.input == event.input
    assert task.context == event.context
    assert task.mode == event.mode
    assert task.submitted_at == event.submitted_at
  end

  test "advances its EventStore cursor incrementally" do
    before =
      :sys.get_state(Current.TaskStore).last_position

    task_id = Id.generate()
    now = DateTime.utc_now()

    event = %Event.TaskCreated{
      id: Id.generate(),
      task_id: task_id,
      input: "cursor test",
      context: %{},
      mode: :plan,
      submitted_at: now,
      timestamp: now
    }

    assert :ok = EventStore.append(event)
    assert :ok = Current.TaskStore.sync()

    after_sync =
      :sys.get_state(Current.TaskStore).last_position

    assert after_sync > before

    assert {:ok, task} =
             Current.TaskStore.get(task_id)

    assert task.id == task_id

    assert :sys.get_state(Current.TaskStore).last_position >= after_sync
  end

  test "ETS contains no task for an unknown task id" do
    unknown =
      "sha256:" <> String.duplicate("a", 64)

    assert [] =
             :ets.lookup(
               @table,
               unknown
             )
  end
end
