defmodule Current.RevisionReducerTest do
  use ExUnit.Case, async: true

  alias Current.{Event, Proposal, Workflow, WorkflowReducer}

  @wf "sha256:wf"
  @t0 ~U[2026-01-01 00:00:00Z]

  defp proposal(id, opts \\ []) do
    %Proposal{
      id: id,
      workflow_id: @wf,
      intents: [],
      revision: Keyword.get(opts, :revision, 0),
      revises: Keyword.get(opts, :revises)
    }
  end

  defp created(opts \\ []) do
    %Event.WorkflowCreated{
      id: "e-created",
      workflow_id: @wf,
      task_id: "t",
      mode: Keyword.get(opts, :mode, :apply),
      max_revisions: Keyword.get(opts, :max_revisions, 10),
      timestamp: @t0
    }
  end

  defp started(n),
    do: %Event.ProposalProductionStarted{id: "s#{n}", workflow_id: @wf, timestamp: @t0}

  defp produced(p),
    do: %Event.ProposalProduced{id: "p-#{p.id}", workflow_id: @wf, proposal: p, timestamp: @t0}

  defp validated(p),
    do: %Event.ProposalValidated{id: "v-#{p.id}", workflow_id: @wf, proposal: p, timestamp: @t0}

  defp revise(p, feedback \\ "change it"),
    do: %Event.ProposalRevisionRequested{
      id: "r-#{p.id}",
      workflow_id: @wf,
      proposal_id: p.id,
      feedback: feedback,
      metadata: %{},
      timestamp: @t0
    }

  defp approve(p),
    do: %Event.ProposalApproved{
      id: "a-#{p.id}",
      workflow_id: @wf,
      proposal_id: p.id,
      metadata: %{},
      timestamp: @t0
    }

  defp reject(p),
    do: %Event.ProposalRejected{
      id: "x-#{p.id}",
      workflow_id: @wf,
      proposal_id: p.id,
      metadata: %{},
      timestamp: @t0
    }

  defp apply_started(proposal_id),
    do: %Event.EffectApplicationStarted{
      id: "as",
      workflow_id: @wf,
      proposal_id: proposal_id,
      timestamp: @t0
    }

  defp replay!(events) do
    {:ok, workflow} = WorkflowReducer.replay(events)
    workflow
  end

  # created -> planning -> validating -> waiting_for_approval, with one proposal
  defp waiting(p1, opts \\ []),
    do: [created(opts), started(1), produced(p1), validated(p1)]

  describe "a workflow's proposals" do
    test "start empty and grow by one per ProposalProduced" do
      assert replay!([created()]).proposals == []

      p1 = proposal("p1")
      w = replay!(waiting(p1))
      assert w.status == :waiting_for_approval
      assert w.proposals == [p1]
      assert Workflow.current_proposal(w) == p1
      assert Workflow.revisions_used(w) == 0
    end

    test "a revision appends and the latest becomes current" do
      p1 = proposal("p1")
      p2 = proposal("p2", revision: 1, revises: "p1")

      w = replay!(waiting(p1) ++ [revise(p1), started(2), produced(p2), validated(p2)])

      assert w.status == :waiting_for_approval
      assert w.proposals == [p1, p2]
      assert Workflow.current_proposal(w).id == "p2"
      assert Workflow.revisions_used(w) == 1
    end

    test "max_revisions is read from WorkflowCreated" do
      assert replay!([created(max_revisions: 3)]).max_revisions == 3
    end
  end

  describe "decisions on the latest proposal" do
    test "approve, reject and revise are accepted" do
      p1 = proposal("p1")
      assert replay!(waiting(p1) ++ [approve(p1)]).status == :approved
      assert replay!(waiting(p1) ++ [reject(p1)]).status == :rejected
      assert replay!(waiting(p1) ++ [revise(p1)]).status == :revision_requested
    end

    test "revision_requested is not terminal, and production restarts from it" do
      p1 = proposal("p1")
      w = replay!(waiting(p1) ++ [revise(p1)])
      refute Workflow.terminal?(w)

      assert replay!(waiting(p1) ++ [revise(p1), started(2)]).status == :planning
    end

    test "started_at keeps the first production start across a revision" do
      p1 = proposal("p1")
      later = ~U[2026-01-01 00:05:00Z]
      second_start = %{started(2) | timestamp: later}

      w = replay!(waiting(p1) ++ [revise(p1), second_start])
      assert w.started_at == @t0
    end
  end

  describe "stale decisions are refused by the reducer" do
    setup do
      p1 = proposal("p1")
      p2 = proposal("p2", revision: 1, revises: "p1")
      events = waiting(p1) ++ [revise(p1), started(2), produced(p2), validated(p2)]
      {:ok, p1: p1, p2: p2, workflow: replay!(events)}
    end

    test "approve", %{p1: p1, workflow: w} do
      assert {:error, {:stale_proposal, "p1", "p2"}} = WorkflowReducer.apply_event(w, approve(p1))
    end

    test "reject", %{p1: p1, workflow: w} do
      assert {:error, {:stale_proposal, "p1", "p2"}} = WorkflowReducer.apply_event(w, reject(p1))
    end

    test "revise", %{p1: p1, workflow: w} do
      assert {:error, {:stale_proposal, "p1", "p2"}} = WorkflowReducer.apply_event(w, revise(p1))
    end

    test "the latest is still accepted", %{p2: p2, workflow: w} do
      assert {:ok, %Workflow{status: :approved}} = WorkflowReducer.apply_event(w, approve(p2))
    end

    test "an id that was never a proposal is stale too", %{workflow: w} do
      assert {:error, {:stale_proposal, "nope", "p2"}} =
               WorkflowReducer.apply_event(w, approve(proposal("nope")))
    end
  end

  describe "EffectApplicationStarted" do
    test "must name the current proposal" do
      p1 = proposal("p1")
      w = replay!(waiting(p1) ++ [approve(p1)])

      assert {:ok, %Workflow{status: :applying}} =
               WorkflowReducer.apply_event(w, apply_started("p1"))

      assert {:error, {:stale_proposal, "old", "p1"}} =
               WorkflowReducer.apply_event(w, apply_started("old"))
    end

    test "a v1 event (proposal_id nil) still replays" do
      p1 = proposal("p1")
      w = replay!(waiting(p1) ++ [approve(p1)])

      assert {:ok, %Workflow{status: :applying}} =
               WorkflowReducer.apply_event(w, apply_started(nil))
    end
  end

  describe "the revision bound" do
    test "the max_revisions+1th request is refused" do
      max = 2

      {events, last} =
        Enum.reduce(1..max, {waiting(proposal("p0"), max_revisions: max), proposal("p0")}, fn n,
                                                                                              {acc,
                                                                                               prev} ->
          next = proposal("p#{n}", revision: n, revises: prev.id)
          {acc ++ [revise(prev), started(n + 1), produced(next), validated(next)], next}
        end)

      w = replay!(events)
      assert Workflow.revisions_used(w) == max

      assert {:error, {:revision_limit_reached, ^max}} =
               WorkflowReducer.apply_event(w, revise(last))

      # approve and reject are unaffected by the bound
      assert {:ok, _} = WorkflowReducer.apply_event(w, approve(last))
      assert {:ok, _} = WorkflowReducer.apply_event(w, reject(last))
    end

    test "max_revisions: 0 allows none" do
      p1 = proposal("p1")
      w = replay!(waiting(p1, max_revisions: 0))
      assert {:error, {:revision_limit_reached, 0}} = WorkflowReducer.apply_event(w, revise(p1))
    end
  end

  describe "where a revision request is not accepted" do
    test "plan-mode workflows cannot be revised" do
      p1 = proposal("p1")
      w = replay!(waiting(p1, mode: :plan))

      assert {:error,
              {:invalid_transition, :waiting_for_approval, Event.ProposalRevisionRequested}} =
               WorkflowReducer.apply_event(w, revise(p1))
    end

    test "not from :validating, :approved or :revision_requested" do
      p1 = proposal("p1")

      validating = replay!([created(), started(1), produced(p1)])

      assert {:error, {:invalid_transition, :validating, _}} =
               WorkflowReducer.apply_event(validating, revise(p1))

      approved = replay!(waiting(p1) ++ [approve(p1)])

      assert {:error, {:invalid_transition, :approved, _}} =
               WorkflowReducer.apply_event(approved, revise(p1))

      requested = replay!(waiting(p1) ++ [revise(p1)])

      assert {:error, {:invalid_transition, :revision_requested, _}} =
               WorkflowReducer.apply_event(requested, revise(p1))
    end

    test "a second approval after a revision request is refused" do
      p1 = proposal("p1")
      w = replay!(waiting(p1) ++ [revise(p1)])

      assert {:error, {:invalid_transition, :revision_requested, _}} =
               WorkflowReducer.apply_event(w, approve(p1))
    end
  end

  describe "proposal lineage (ProposalProduced)" do
    defp planning_first, do: replay!([created(), started(1)])

    defp planning_replacement(p1 \\ proposal("p1")),
      do: replay!(waiting(p1) ++ [revise(p1), started(2)])

    test "a first proposal with revision 0 and no revises is accepted" do
      assert {:ok, %Workflow{status: :validating, proposals: [%{id: "p1"}]}} =
               WorkflowReducer.apply_event(planning_first(), produced(proposal("p1")))
    end

    test "a first proposal claiming a revision is refused" do
      assert {:error, {:invalid_proposal_lineage, %{new_revision: 1, new_revises: nil}}} =
               WorkflowReducer.apply_event(
                 planning_first(),
                 produced(proposal("p1", revision: 1))
               )
    end

    test "a first proposal claiming to replace something is refused" do
      assert {:error, {:invalid_proposal_lineage, %{new_revision: 0, new_revises: "ghost"}}} =
               WorkflowReducer.apply_event(
                 planning_first(),
                 produced(proposal("p1", revises: "ghost"))
               )
    end

    test "a replacement revising the current proposal, one step on, is accepted" do
      p2 = proposal("p2", revision: 1, revises: "p1")

      assert {:ok, %Workflow{status: :validating} = w} =
               WorkflowReducer.apply_event(planning_replacement(), produced(p2))

      assert Enum.map(w.proposals, & &1.id) == ["p1", "p2"]
    end

    test "a replacement revising some other id is refused" do
      p2 = proposal("p2", revision: 1, revises: "other")

      assert {:error, {:invalid_proposal_lineage, %{tail_id: "p1", new_revises: "other"}}} =
               WorkflowReducer.apply_event(planning_replacement(), produced(p2))
    end

    test "a replacement revising nothing is refused" do
      p2 = proposal("p2", revision: 1, revises: nil)

      assert {:error, {:invalid_proposal_lineage, %{tail_id: "p1", new_revises: nil}}} =
               WorkflowReducer.apply_event(planning_replacement(), produced(p2))
    end

    test "a replacement whose revision number doesn't follow the tail is refused" do
      for revision <- [0, 2, 7] do
        p2 = proposal("p2", revision: revision, revises: "p1")

        assert {:error, {:invalid_proposal_lineage, %{tail_revision: 0, new_revision: ^revision}}} =
                 WorkflowReducer.apply_event(planning_replacement(), produced(p2))
      end
    end

    test "a replacement reusing the tail's id is refused" do
      dup = proposal("p1", revision: 1, revises: "p1")

      assert {:error, {:invalid_proposal_lineage, %{tail_id: "p1", new_id: "p1"}}} =
               WorkflowReducer.apply_event(planning_replacement(), produced(dup))
    end

    test "only the tail can be revised, not an earlier proposal" do
      p1 = proposal("p1")
      p2 = proposal("p2", revision: 1, revises: "p1")

      w =
        replay!(
          waiting(p1) ++
            [revise(p1), started(2), produced(p2), validated(p2), revise(p2), started(3)]
        )

      skipping = proposal("p3", revision: 2, revises: "p1")

      assert {:error, {:invalid_proposal_lineage, %{tail_id: "p2", new_revises: "p1"}}} =
               WorkflowReducer.apply_event(w, produced(skipping))

      p3 = proposal("p3", revision: 2, revises: "p2")
      assert {:ok, %Workflow{status: :validating}} = WorkflowReducer.apply_event(w, produced(p3))
    end

    test "replay stops at a proposal with a broken lineage" do
      p1 = proposal("p1")
      bad = proposal("p2", revision: 1, revises: "other")

      assert {:error, {:invalid_proposal_lineage, _}} =
               WorkflowReducer.replay(waiting(p1) ++ [revise(p1), started(2), produced(bad)])
    end
  end

  describe "failure paths are unchanged" do
    test "a revision that fails validation fails the workflow" do
      p1 = proposal("p1")
      p2 = proposal("p2", revision: 1, revises: "p1")

      failed = %Event.ProposalValidationFailed{
        id: "vf",
        workflow_id: @wf,
        proposal: p2,
        error: %Current.Error.ValidationError{intent_id: "i", reason: "bad"},
        timestamp: @t0
      }

      wf_failed = %Event.WorkflowFailed{
        id: "wf",
        workflow_id: @wf,
        reason: "proposal validation failed",
        timestamp: @t0
      }

      w = replay!(waiting(p1) ++ [revise(p1), started(2), produced(p2), failed, wf_failed])
      assert w.status == :failed
      assert Workflow.terminal?(w)
    end

    test "WorkflowAbandoned covers :revision_requested" do
      p1 = proposal("p1")

      abandoned = %Event.WorkflowAbandoned{
        id: "ab",
        workflow_id: @wf,
        reason: "gave up",
        timestamp: @t0
      }

      assert replay!(waiting(p1) ++ [revise(p1), abandoned]).status == :abandoned
    end
  end
end
