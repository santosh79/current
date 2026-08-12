defmodule Current.EventStoreTest do
  use ExUnit.Case, async: false

  alias Current.{Event, EventStore, Id}

  test "returns only events for the workflow sorted by timestamp" do
    workflow_id = Id.generate()
    other_workflow_id = Id.generate()
    task_id = Id.generate()

    t0 = ~U[2026-08-11 12:00:00Z]

    first = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: task_id,
      mode: :apply,
      timestamp: DateTime.add(t0, 1, :second)
    }

    second = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.add(t0, 2, :second)
    }

    third = %Event.WorkflowCompleted{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.add(t0, 3, :second)
    }

    other = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: other_workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: t0
    }

    # Deliberately append out of timestamp order.
    [first, second, third, other] |>
    Enum.shuffle() |>
    Enum.map(fn(ev) ->
      :ok = EventStore.append(ev)
    end)

    assert [first, second, third] ==
             EventStore.list_by_workflow_id(workflow_id)
  end

  test "returns an empty list for an unknown workflow" do
    unknown_workflow_id = Id.generate()

    assert [] == EventStore.list_by_workflow_id(unknown_workflow_id)
  end
end
