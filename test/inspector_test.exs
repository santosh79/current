defmodule Current.InspectorTest do
  use ExUnit.Case, async: false

  alias Current.{Event, Inspector, Request}

  defp planned_workflow! do
    {:ok, task_id} =
      Current.submit_task(
        %Request{input: "x", context: %{}, mode: :plan},
        self(),
        System.tmp_dir!()
      )

    receive do
      {:workflow_completed, %Event.WorkflowCompleted{workflow_id: id}} -> {task_id, id}
    after
      5_000 -> flunk("workflow did not complete")
    end
  end

  test "workflow/1 returns TaskCreated then the workflow stream, in log order" do
    {task_id, workflow_id} = planned_workflow!()

    assert {:ok, view} = Inspector.workflow(workflow_id)
    assert view.task.id == task_id
    assert [%{event: %Event.TaskCreated{task_id: ^task_id}} | _] = view.entries
    positions = Enum.map(view.entries, & &1.position)
    assert positions == Enum.sort(positions)
    assert Inspector.workflow(task_id) == {:ok, view}
  end

  test "proposal/1 resolves a prefix and links the raw output and status" do
    {_task_id, workflow_id} = planned_workflow!()
    {:ok, workflow} = Current.WorkflowStore.get(workflow_id)
    "sha256:" <> hex = workflow.proposal.id

    assert {:ok, view} = Inspector.proposal(String.slice(hex, 0, 12))
    assert view.proposal.id == workflow.proposal.id
    assert view.workflow_id == workflow_id
    assert view.status == :planned
    assert view.validation_error == nil
  end

  test "artifact/1 resolves prefixes, and refuses ambiguous or too-short ones" do
    {:ok, id} = Current.BlobStore.put("inspector artifact #{System.unique_integer()}")
    assert {:ok, ^id, "inspector artifact" <> _} = Inspector.artifact(String.slice(id, 0, 20))

    prefix = colliding_prefix()
    assert {:error, {:ambiguous, [_, _ | _] = ids}} = Inspector.artifact(prefix)
    assert Enum.all?(ids, &String.starts_with?(&1, prefix))

    assert {:error, :prefix_too_short} = Inspector.artifact("ab")
    assert {:error, :not_found} = Inspector.artifact("not-hex!")
  end

  # Stores blobs until two share a 4-hex-digit prefix (the shortest that
  # is accepted); by the birthday bound that takes a few hundred.
  defp colliding_prefix(seen \\ %{}) do
    {:ok, "sha256:" <> hex} = Current.BlobStore.put("collide #{System.unique_integer()}")
    prefix = "sha256:" <> String.slice(hex, 0, 4)

    if Map.has_key?(seen, prefix), do: prefix, else: colliding_prefix(Map.put(seen, prefix, true))
  end
end
