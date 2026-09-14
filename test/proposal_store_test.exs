defmodule Current.ProposalStoreTest do
  use ExUnit.Case, async: false

  alias Current.{
    Event,
    EventStore,
    Id,
    Intent,
    Proposal
  }

  @table Current.ProposalStore

  test "projects a committed ProposalProduced event into ETS" do
    proposal = proposal_fixture()
    :ok = advance_to_planning(proposal.workflow_id)

    event = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: proposal.workflow_id,
      proposal: proposal,
      timestamp: DateTime.utc_now()
    }

    assert :ok = EventStore.append(event)

    # Synchronize the projection before inspecting ETS.
    assert :ok = Current.ProposalStore.sync()

    assert [{proposal_id, stored}] =
             :ets.lookup(
               @table,
               proposal.id
             )

    assert proposal_id == proposal.id
    assert stored == proposal
  end

  test "advances its EventStore cursor incrementally" do
    before =
      :sys.get_state(Current.ProposalStore).last_position

    proposal = proposal_fixture()
    :ok = advance_to_planning(proposal.workflow_id)

    event = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: proposal.workflow_id,
      proposal: proposal,
      timestamp: DateTime.utc_now()
    }

    assert :ok =
             EventStore.append(event)

    assert :ok =
             Current.ProposalStore.sync()

    after_sync =
      :sys.get_state(Current.ProposalStore).last_position

    assert after_sync > before

    assert {:ok, stored} =
             Current.ProposalStore.get(proposal.id)

    assert stored == proposal

    # The cursor must never move backwards.
    assert :sys.get_state(Current.ProposalStore).last_position >= after_sync
  end

  test "ETS contains no proposal for an unknown proposal id" do
    unknown =
      "sha256:" <> String.duplicate("a", 64)

    assert [] =
             :ets.lookup(
               @table,
               unknown
             )
  end

  defp advance_to_planning(workflow_id) do
    :ok =
      EventStore.append(%Event.WorkflowCreated{
        id: Id.generate(),
        workflow_id: workflow_id,
        task_id: Id.generate(),
        mode: :apply,
        timestamp: DateTime.utc_now()
      })

    :ok =
      EventStore.append(%Event.ProposalProductionStarted{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      })

    :ok
  end

  defp proposal_fixture do
    workflow_id = Id.generate()
    proposal_id = Id.generate()

    intent = %Intent.RunCommand{
      id: Id.generate(),
      proposal_id: proposal_id,
      cmd: "echo",
      args: ["hello"]
    }

    %Proposal{
      id: proposal_id,
      workflow_id: workflow_id,
      intents: [intent],
      justification: "test proposal",
      claims: [],
      dependencies: []
    }
  end
end
