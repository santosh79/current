defmodule Current.RevisionWorkflowTest do
  use ExUnit.Case, async: true

  alias Current.Workflow

  defp wf(proposals),
    do: %Workflow{
      id: "w",
      task_id: "t",
      status: :created,
      created_at: DateTime.utc_now(),
      proposals: proposals
    }

  test "current_proposal/1 is the last one, or nil" do
    assert Workflow.current_proposal(wf([])) == nil
    assert Workflow.current_proposal(wf([%{id: 1}, %{id: 2}])) == %{id: 2}
  end

  test "revisions_used/1 is length - 1, floored at 0" do
    assert Workflow.revisions_used(wf([])) == 0
    assert Workflow.revisions_used(wf([%{}])) == 0
    assert Workflow.revisions_used(wf([%{}, %{}, %{}])) == 2
  end

  test "revision_requested is a known, non-terminal status" do
    assert :revision_requested in Workflow.statuses()
    refute Workflow.terminal?(%{wf([]) | status: :revision_requested})
  end

  test "max_revisions defaults to 10" do
    assert wf([]).max_revisions == 10
  end
end
