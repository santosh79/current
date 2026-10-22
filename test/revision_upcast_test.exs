defmodule Current.RevisionUpcastTest do
  use ExUnit.Case, async: true

  alias Current.Event
  alias Current.Event.Schema

  @t ~U[2026-01-01 00:00:00Z]

  defp old_proposal do
    # As written before :observations, :revision and :revises existed.
    %{__struct__: Current.Proposal, id: "p", workflow_id: "w", intents: []}
  end

  test "WorkflowCreated v1 gets max_revisions: 10" do
    raw = %{
      __struct__: Event.WorkflowCreated,
      version: 1,
      id: "e",
      workflow_id: "w",
      task_id: "t",
      mode: :apply,
      timestamp: @t
    }

    assert %Event.WorkflowCreated{max_revisions: 10, version: 2} = Schema.upcast(raw)
  end

  test "EffectApplicationStarted v1 gets proposal_id: nil" do
    raw = %{
      __struct__: Event.EffectApplicationStarted,
      version: 1,
      id: "e",
      workflow_id: "w",
      timestamp: @t
    }

    assert %Event.EffectApplicationStarted{proposal_id: nil, version: 2} = Schema.upcast(raw)
  end

  for {mod, versions} <- [
        {Event.ProposalProduced, [1, 2, 3]},
        {Event.ProposalValidated, [1, 2]},
        {Event.ProposalValidationFailed, [1, 2]}
      ],
      version <- versions do
    test "#{inspect(mod)} v#{version} brings its proposal up to date" do
      raw = %{
        __struct__: unquote(mod),
        version: unquote(version),
        id: "e",
        workflow_id: "w",
        proposal: old_proposal(),
        error: nil,
        timestamp: @t
      }

      event = Schema.upcast(raw)
      assert event.proposal.revision == 0
      assert event.proposal.revises == nil
      assert event.proposal.observations == []
    end
  end

  test "Proposal.upcast keeps fields that are already present" do
    p = Map.merge(old_proposal(), %{observations: [:x], revision: 3, revises: "q"})
    assert %{observations: [:x], revision: 3, revises: "q"} = Current.Proposal.upcast(p)
  end

  test "the new event is registered" do
    assert Event.ProposalRevisionRequested in Event.modules()

    assert Event.valid?(%Event.ProposalRevisionRequested{
             id: "e",
             workflow_id: "w",
             proposal_id: "p",
             feedback: "f",
             metadata: %{},
             timestamp: @t
           })
  end
end
