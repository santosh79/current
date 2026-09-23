defmodule Current.EventStoreTest do
  use ExUnit.Case, async: false

  alias Current.{Event, EventStore, Id}

  test "returns only events for the workflow in commit order" do
    workflow_id = Id.generate()
    other_workflow_id = Id.generate()
    task_id = Id.generate()

    t0 = ~U[2026-08-11 12:00:00Z]

    first = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: task_id,
      mode: :apply,
      timestamp: DateTime.add(t0, 3, :second)
    }

    second = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.add(t0, 2, :second)
    }

    third = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.add(t0, 1, :second)
    }

    other = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: other_workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: t0
    }

    :ok = EventStore.append(first)
    :ok = EventStore.append(other)
    :ok = EventStore.append(second)
    :ok = EventStore.append(third)

    assert EventStore.list_by_workflow_id(workflow_id) ==
             [first, second, third]
  end

  test "returns an empty list for an unknown workflow" do
    unknown_workflow_id = Id.generate()

    assert [] == EventStore.list_by_workflow_id(unknown_workflow_id)
  end

  test "complete_log_entries returns all events in insertion order" do
    workflow_id = Id.generate()
    task_id = Id.generate()

    t0 = ~U[2026-08-11 12:00:00Z]

    first = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: task_id,
      mode: :apply,
      timestamp: DateTime.add(t0, 3, :second)
    }

    second = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.add(t0, 2, :second)
    }

    third = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.add(t0, 1, :second)
    }

    assert :ok = EventStore.append(first)
    assert :ok = EventStore.append(second)
    assert :ok = EventStore.append(third)

    assert {:ok, entries} =
             EventStore.complete_log_entries()

    # complete_log_entries itself must already be in canonical commit order.
    assert entries ==
             Enum.sort_by(
               entries,
               & &1.position
             )

    first_entry = Enum.find(entries, fn ent -> ent.event.id == first.id end)
    second_entry = Enum.find(entries, fn ent -> ent.event.id == second.id end)
    third_entry = Enum.find(entries, fn ent -> ent.event.id == third.id end)

    assert first_entry.position < second_entry.position
    assert second_entry.position < third_entry.position
  end

  ## Subscription
  test "all subscribers receive every committed event" do
    :ok = Current.EventNotifier.subscribe(self(), :all)

    now = DateTime.utc_now()

    event = %Event.TaskCreated{
      id: Id.generate(),
      task_id: Id.generate(),
      input: "test task",
      context: %{},
      mode: :apply,
      project_dir: Current.TestTmp.dir(),
      submitted_at: now,
      timestamp: now
    }

    assert :ok = EventStore.append(event)

    assert_receive {
      :event_committed,
      %Current.EventStore.Entry{event: ^event}
    }
  end

  test "workflow all subscriber receives events for that workflow" do
    workflow_id = Id.generate()

    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :all)

    event = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(event)

    assert_receive {
      :event_committed,
      %Current.EventStore.Entry{event: ^event}
    }
  end

  test "workflow subscriber does not receive events for another workflow" do
    workflow_id = Id.generate()
    other_workflow_id = Id.generate()

    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :all)

    event = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: other_workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(event)

    refute_receive {:event_committed, _}, 100
  end

  test "workflow event subscriber receives only matching event type for that workflow" do
    workflow_id = Id.generate()

    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :workflow_completed)

    genesis = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: Id.generate(),
      mode: :plan,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(genesis)

    unrelated = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(unrelated)
    refute_receive {:event_committed, _}, 100

    # Advance the workflow to a status WorkflowCompleted is legal from --
    # unrelated to the type-filtering this test actually checks.
    assert :ok =
             EventStore.append(%Event.ProposalProduced{
               id: Id.generate(),
               workflow_id: workflow_id,
               timestamp: DateTime.utc_now()
             })

    assert :ok =
             EventStore.append(%Event.ProposalValidated{
               id: Id.generate(),
               workflow_id: workflow_id,
               proposal: nil,
               timestamp: DateTime.utc_now()
             })

    matching = %Event.WorkflowCompleted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(matching)

    assert_receive {
      :event_committed,
      %Current.EventStore.Entry{event: ^matching}
    }
  end

  test "subscriber matching multiple subscriptions is notified only once" do
    workflow_id = Id.generate()

    :ok = Current.EventNotifier.subscribe(self(), :all)
    :ok = Current.EventNotifier.subscribe(self(), :workflow_completed)
    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :all)
    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :workflow_completed)

    assert :ok =
             EventStore.append(%Event.WorkflowCreated{
               id: Id.generate(),
               workflow_id: workflow_id,
               task_id: Id.generate(),
               mode: :plan,
               timestamp: DateTime.utc_now()
             })

    assert :ok =
             EventStore.append(%Event.ProposalProductionStarted{
               id: Id.generate(),
               workflow_id: workflow_id,
               timestamp: DateTime.utc_now()
             })

    assert :ok =
             EventStore.append(%Event.ProposalProduced{
               id: Id.generate(),
               workflow_id: workflow_id,
               timestamp: DateTime.utc_now()
             })

    assert :ok =
             EventStore.append(%Event.ProposalValidated{
               id: Id.generate(),
               workflow_id: workflow_id,
               proposal: nil,
               timestamp: DateTime.utc_now()
             })

    event = %Event.WorkflowCompleted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(event)

    assert_receive {
      :event_committed,
      %Current.EventStore.Entry{event: ^event}
    }

    refute_receive {
                     :event_committed,
                     %Current.EventStore.Entry{event: ^event}
                   },
                   100
  end

  test "entries_after returns entries strictly after a position up to the limit" do
    workflow_id = Id.generate()
    task_id = Id.generate()

    first = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: task_id,
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    second = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    third = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    :ok = EventStore.append(first)
    :ok = EventStore.append(second)
    :ok = EventStore.append(third)

    {:ok, all_entries} = EventStore.complete_log_entries()
    first_entry = Enum.find(all_entries, &(&1.event.id == first.id))
    assert {:ok, entries} = EventStore.entries_after(first_entry.position, 50)

    own_events =
      entries
      |> Enum.map(& &1.event)
      |> Enum.filter(&(Map.get(&1, :workflow_id) == workflow_id))

    assert own_events == [second, third]
  end

  test "entries_after respects limit" do
    workflow_id = Id.generate()

    :ok =
      EventStore.append(%Event.WorkflowCreated{
        id: Id.generate(),
        workflow_id: workflow_id,
        task_id: Id.generate(),
        mode: :apply,
        timestamp: DateTime.utc_now()
      })

    events = [
      %Event.ProposalProductionStarted{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      },
      %Event.ProposalProduced{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      },
      %Event.ProposalValidated{
        id: Id.generate(),
        workflow_id: workflow_id,
        proposal: nil,
        timestamp: DateTime.utc_now()
      }
    ]

    Enum.each(events, fn event ->
      :ok = EventStore.append(event)
    end)

    {:ok, entries} =
      EventStore.entries_after(
        0,
        2
      )

    assert length(entries) == 2
  end
end
