defmodule Current.WorkflowStoreTest do
  use ExUnit.Case, async: false

  alias Current.{Id, Proposal, Workflow, WorkflowStore}

  defp workflow(overrides \\ %{}) do
    now = DateTime.utc_now()

    defaults = %{
      id: Id.generate(),
      task_id: Id.generate(),
      status: :waiting_for_approval,
      proposal: nil,
      result: nil,
      events: [],
      mode: :apply,
      started_at: now,
      created_at: now,
      completed_at: nil,
      updated_at: now,
      error: nil
    }

    struct!(Workflow, Map.merge(defaults, overrides))
  end

  test "put/get round trip preserves workflow" do
    workflow = workflow()
    assert :ok = WorkflowStore.put(workflow)
    assert {:ok, ^workflow} = WorkflowStore.get(workflow.id)
  end

  test "put replaces the projection for an existing workflow id" do
    workflow = workflow(%{status: :created})
    updated = %{workflow | status: :completed, completed_at: DateTime.utc_now()}

    assert :ok = WorkflowStore.put(workflow)
    assert :ok = WorkflowStore.put(updated)
    assert {:ok, ^updated} = WorkflowStore.get(workflow.id)
  end

  test "get_by_task_id finds the workflow for a task" do
    workflow = workflow()
    assert :ok = WorkflowStore.put(workflow)
    assert {:ok, ^workflow} = WorkflowStore.get_by_task_id(workflow.task_id)
  end

  test "get_status_by_task_id returns the projected status" do
    workflow = workflow(%{status: :planned, mode: :plan})
    assert :ok = WorkflowStore.put(workflow)
    assert {:ok, :planned} = WorkflowStore.get_status_by_task_id(workflow.task_id)
  end

  test "get_by_proposal_id finds a workflow by its proposal" do
    workflow_id = Id.generate()

    proposal = %Proposal{
      id: Id.generate(),
      workflow_id: workflow_id,
      intents: []
    }

    workflow = workflow(%{id: workflow_id, proposal: proposal})

    assert :ok = WorkflowStore.put(workflow)
    assert {:ok, ^workflow} = WorkflowStore.get_by_proposal_id(proposal.id)
  end

  test "lookup functions return not_found when no workflow matches" do
    unknown = "sha256:" <> String.duplicate("b", 64)

    assert {:error, :not_found} = WorkflowStore.get(unknown)
    assert {:error, :not_found} = WorkflowStore.get_by_task_id(unknown)
    assert {:error, :not_found} = WorkflowStore.get_status_by_task_id(unknown)
    assert {:error, :not_found} = WorkflowStore.get_by_proposal_id(unknown)
  end
end
