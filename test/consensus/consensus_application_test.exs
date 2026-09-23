defmodule Current.ConsensusApplicationTest do
  @moduledoc """
  Consensus used to be a side path: SingleNodeServer + EventCommitter
  existed and had their own tests, but nothing in the actual submit_task/
  review_proposal/orchestrator write path went through them. This test
  exercises the real, public API exactly the way any caller would, then
  checks a property that would be meaningless before this refactor and is
  now a genuine architectural guarantee: every event that becomes
  canonical in EventStore got there by having already gone through
  consensus, not because some process decided to write it.
  """

  use ExUnit.Case, async: false

  alias Current.Request

  @receive_timeout 5_000

  defp request(mode \\ :apply) do
    %Request{
      input: "add email validation to signup flow",
      context: %{},
      mode: mode
    }
  end

  defp assert_all_events_went_through_consensus(workflow_id) do
    events = Current.EventStore.list_by_workflow_id(workflow_id)
    assert events != [], "expected at least one event for workflow #{workflow_id}"

    for event <- events do
      assert {:ok, ^event} = Current.Consensus.Log.get(event.id),
             "expected #{inspect(event.__struct__)} (#{event.id}) to be present in " <>
               "Consensus.Log -- it's canonical in EventStore but consensus has no record of it"
    end
  end

  test "TaskCreated itself goes through consensus" do
    {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

    receive do
      {:workflow_created, %Current.Event.WorkflowCreated{task_id: ^task_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_created")
    end

    {:ok, entries} = Current.EventStore.complete_log_entries()

    task_created_event =
      entries
      |> Enum.map(& &1.event)
      |> Enum.find(&match?(%Current.Event.TaskCreated{task_id: ^task_id}, &1))

    assert task_created_event,
           "expected to find a TaskCreated event for task #{task_id} in EventStore"

    assert {:ok, ^task_created_event} = Current.Consensus.Log.get(task_created_event.id)
  end

  test "a completed apply-mode workflow's entire event stream is backed by consensus" do
    {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

    workflow_id =
      receive do
        {:workflow_created, %Current.Event.WorkflowCreated{task_id: ^task_id, workflow_id: wid}} ->
          wid
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    proposal =
      receive do
        {:proposal_produced, %Current.Event.ProposalProduced{proposal: proposal}} -> proposal
      after
        @receive_timeout -> flunk("did not receive proposal_produced")
      end

    receive do
      {:proposal_validated, _event} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_validated")
    end

    assert :ok = Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :consensus_test}})

    receive do
      {:workflow_completed, _event} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_completed")
    end

    assert_all_events_went_through_consensus(workflow_id)
  end

  test "a plan-mode workflow's entire event stream is backed by consensus" do
    {:ok, task_id} = Current.submit_task(request(:plan), self(), System.tmp_dir!())

    workflow_id =
      receive do
        {:workflow_created, %Current.Event.WorkflowCreated{task_id: ^task_id, workflow_id: wid}} ->
          wid
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    receive do
      {:workflow_completed, _event} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_completed")
    end

    assert_all_events_went_through_consensus(workflow_id)
  end
end
