defmodule Current.WorkflowReducerTest do
  use ExUnit.Case, async: true

  alias Current.{Event, Intent, Proposal, Workflow, WorkflowReducer, WorkflowResult}
  alias Current.Error.ValidationError

  @workflow_id "sha256:" <> String.duplicate("a", 64)
  @task_id "sha256:" <> String.duplicate("b", 64)
  @proposal_id "sha256:" <> String.duplicate("c", 64)
  @t0 ~U[2026-07-25 12:00:00.000000Z]

  defp ts(seconds), do: DateTime.add(@t0, seconds, :second)

  defp event_id do
    n = System.unique_integer([:positive, :monotonic])
    "sha256:" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")
  end

  defp genesis(mode \\ :apply) do
    %Event.WorkflowCreated{
      id: event_id(),
      workflow_id: @workflow_id,
      task_id: @task_id,
      mode: mode,
      timestamp: ts(0)
    }
  end

  defp proposal do
    %Proposal{
      id: @proposal_id,
      workflow_id: @workflow_id,
      intents: [intent()]
    }
  end

  defp intent do
    %Intent.RunCommand{
      id: "sha256:" <> String.duplicate("d", 64),
      proposal_id: @proposal_id,
      cmd: "echo",
      args: ["hello"]
    }
  end

  defp workflow_result do
    %WorkflowResult{
      id: "sha256:" <> String.duplicate("e", 64),
      workflow_id: @workflow_id,
      type: :result_bundle,
      artifacts: [],
      created_at: ts(7)
    }
  end

  # A workflow driven up to :waiting_for_approval — a convenient midpoint.
  defp waiting_for_approval(mode \\ :apply) do
    WorkflowReducer.replay([
      genesis(mode),
      %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(1)
      },
      %Event.ProposalProduced{
        id: event_id(),
        workflow_id: @workflow_id,
        proposal: proposal(),
        timestamp: ts(2)
      },
      %Event.ProposalValidated{
        id: event_id(),
        workflow_id: @workflow_id,
        proposal: proposal(),
        timestamp: ts(3)
      }
    ])
  end

  describe "genesis (WorkflowCreated)" do
    test "builds the initial workflow entirely from the event's facts" do
      w = WorkflowReducer.apply_event(nil, genesis())

      assert %Workflow{} = w
      assert w.id == @workflow_id
      assert w.task_id == @task_id
      assert w.mode == :apply
      assert w.status == :created
      assert w.created_at == ts(0)
      assert w.updated_at == ts(0)
      assert w.proposal == nil
      assert w.result == nil
      assert w.events == []
      assert w.started_at == nil
      assert w.completed_at == nil
      assert w.error == nil
    end

    test "is deterministic — the same event always yields the same workflow" do
      event = genesis()

      assert WorkflowReducer.apply_event(nil, event) ==
               WorkflowReducer.apply_event(nil, event)
    end

    test "carries the mode through, including :plan" do
      assert WorkflowReducer.apply_event(nil, genesis(:plan)).mode == :plan
    end
  end

  describe "planning" do
    test "ProposalProductionStarted moves to :planning and starts the clock" do
      w0 = WorkflowReducer.apply_event(nil, genesis())

      event = %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(1)
      }

      w = WorkflowReducer.apply_event(w0, event)

      assert w.status == :planning
      assert w.started_at == ts(1)
      assert w.updated_at == ts(1)
      assert w.created_at == ts(0)
    end

    test "started_at is set exactly once" do
      w0 = WorkflowReducer.apply_event(nil, genesis())

      first_event = %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(1)
      }

      second_event = %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(99)
      }

      w1 = WorkflowReducer.apply_event(w0, first_event)
      w2 = WorkflowReducer.apply_event(w1, second_event)

      assert w2.started_at == ts(1)
      assert w2.updated_at == ts(99)
    end

    test "ModeInvalid moves to :invalid_mode" do
      w0 = WorkflowReducer.apply_event(nil, genesis(:simulate))

      event = %Event.ModeInvalid{
        id: event_id(),
        workflow_id: @workflow_id,
        mode: :simulate,
        timestamp: ts(1)
      }

      w = WorkflowReducer.apply_event(w0, event)

      assert w.status == :invalid_mode
      assert w.updated_at == ts(1)
    end

    test "ProposalProduced records the proposal and moves to :validating" do
      proposal = proposal()

      w =
        WorkflowReducer.replay([
          genesis(),
          %Event.ProposalProductionStarted{
            id: event_id(),
            workflow_id: @workflow_id,
            timestamp: ts(1)
          },
          %Event.ProposalProduced{
            id: event_id(),
            workflow_id: @workflow_id,
            proposal: proposal,
            timestamp: ts(2)
          }
        ])

      assert w.status == :validating
      assert w.proposal == proposal
      assert w.updated_at == ts(2)
    end
  end

  describe "validation" do
    test "ProposalValidated moves to :waiting_for_approval" do
      w = waiting_for_approval()

      assert w.status == :waiting_for_approval
      assert w.proposal == proposal()
      assert w.updated_at == ts(3)
    end

    test "ProposalValidationFailed extracts the reason from a ValidationError" do
      error = %ValidationError{
        intent_id: nil,
        reason: "path does not exist"
      }

      w =
        WorkflowReducer.replay([
          genesis(),
          %Event.ProposalProductionStarted{
            id: event_id(),
            workflow_id: @workflow_id,
            timestamp: ts(1)
          },
          %Event.ProposalProduced{
            id: event_id(),
            workflow_id: @workflow_id,
            proposal: proposal(),
            timestamp: ts(2)
          },
          %Event.ProposalValidationFailed{
            id: event_id(),
            workflow_id: @workflow_id,
            proposal: proposal(),
            error: error,
            timestamp: ts(3)
          }
        ])

      assert w.status == :validation_failed
      assert w.error == "path does not exist"
      assert w.updated_at == ts(3)
    end

    test "ProposalValidationFailed tolerates a bare error term" do
      w0 = WorkflowReducer.apply_event(nil, genesis())

      event = %Event.ProposalValidationFailed{
        id: event_id(),
        workflow_id: @workflow_id,
        proposal: proposal(),
        error: :inscrutable,
        timestamp: ts(1)
      }

      w = WorkflowReducer.apply_event(w0, event)

      assert w.status == :validation_failed
      assert w.error == :inscrutable
    end
  end

  describe "approval" do
    test "ProposalApproved moves to :approved" do
      event = %Event.ProposalApproved{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      w = WorkflowReducer.apply_event(waiting_for_approval(), event)

      assert w.status == :approved
      assert w.updated_at == ts(4)
    end

    test "ProposalRejected moves to :rejected" do
      event = %Event.ProposalRejected{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      w = WorkflowReducer.apply_event(waiting_for_approval(), event)

      assert w.status == :rejected
      assert w.updated_at == ts(4)
      assert w.completed_at == nil
    end
  end

  describe "effect application" do
    test "EffectApplicationStarted moves to :applying" do
      approved_event = %Event.ProposalApproved{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      started_event = %Event.EffectApplicationStarted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(5)
      }

      w0 = WorkflowReducer.apply_event(waiting_for_approval(), approved_event)
      w = WorkflowReducer.apply_event(w0, started_event)

      assert w.status == :applying
      assert w.updated_at == ts(5)
    end

    test "fact-only events leave the workflow untouched" do
      approved_event = %Event.ProposalApproved{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      started_event = %Event.EffectApplicationStarted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(5)
      }

      w0 = WorkflowReducer.apply_event(waiting_for_approval(), approved_event)
      w = WorkflowReducer.apply_event(w0, started_event)

      facts = [
        %Event.EffectApplied{
          id: event_id(),
          workflow_id: @workflow_id,
          intent: intent(),
          result: :fake_result,
          timestamp: ts(6)
        },
        %Event.EffectsApplied{
          id: event_id(),
          workflow_id: @workflow_id,
          intent_results: [{intent(), :fake_result}],
          timestamp: ts(6)
        },
        %Event.EffectFailed{
          id: event_id(),
          workflow_id: @workflow_id,
          intent: intent(),
          reason: "boom",
          timestamp: ts(6)
        },
        %Event.ArtifactProduced{
          id: event_id(),
          workflow_id: @workflow_id,
          intent: intent(),
          result: :fake_result,
          artifact: :fake_artifact,
          timestamp: ts(6)
        },
        %Event.ArtifactsProduced{
          id: event_id(),
          workflow_id: @workflow_id,
          artifacts: [:fake_artifact],
          timestamp: ts(6)
        }
      ]

      for fact <- facts do
        assert WorkflowReducer.apply_event(w, fact) == w
      end
    end
  end

  describe "result assembly and terminal states" do
    test "WorkflowResultAssembled records the result and moves to :assembling_result" do
      result = workflow_result()

      approved_event = %Event.ProposalApproved{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      result_event = %Event.WorkflowResultAssembled{
        id: event_id(),
        workflow_id: @workflow_id,
        result: result,
        timestamp: ts(7)
      }

      w0 = WorkflowReducer.apply_event(waiting_for_approval(), approved_event)
      w = WorkflowReducer.apply_event(w0, result_event)

      assert w.status == :assembling_result
      assert w.result == result
      assert w.updated_at == ts(7)
    end

    test "WorkflowCompleted lands on :completed for apply mode" do
      approved_event = %Event.ProposalApproved{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      completed_event = %Event.WorkflowCompleted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(8)
      }

      w0 = WorkflowReducer.apply_event(waiting_for_approval(:apply), approved_event)
      w = WorkflowReducer.apply_event(w0, completed_event)

      assert w.status == :completed
      assert w.completed_at == ts(8)
      assert w.updated_at == ts(8)
    end

    test "WorkflowCompleted lands on :planned for plan mode" do
      event = %Event.WorkflowCompleted{
        id: event_id(),
        workflow_id: @workflow_id,
        timestamp: ts(4)
      }

      w = WorkflowReducer.apply_event(waiting_for_approval(:plan), event)

      assert w.status == :planned
      assert w.completed_at == ts(4)
      assert w.result == nil
    end

    test "WorkflowFailed records the reason and moves to :failed" do
      w0 = WorkflowReducer.apply_event(nil, genesis())

      event = %Event.WorkflowFailed{
        id: event_id(),
        workflow_id: @workflow_id,
        reason: "invalid mode: :simulate",
        timestamp: ts(1)
      }

      w = WorkflowReducer.apply_event(w0, event)

      assert w.status == :failed
      assert w.error == "invalid mode: :simulate"
      assert w.updated_at == ts(1)
    end
  end

  describe "replay/1" do
    test "returns nil for an empty stream" do
      assert WorkflowReducer.replay([]) == nil
    end

    test "folds a full happy-path stream to :completed, deterministically" do
      result = workflow_result()

      events = [
        genesis(),
        %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: @workflow_id,
          timestamp: ts(1)
        },
        %Event.ProposalProduced{
          id: event_id(),
          workflow_id: @workflow_id,
          proposal: proposal(),
          timestamp: ts(2)
        },
        %Event.ProposalValidated{
          id: event_id(),
          workflow_id: @workflow_id,
          proposal: proposal(),
          timestamp: ts(3)
        },
        %Event.ProposalApproved{
          id: event_id(),
          workflow_id: @workflow_id,
          timestamp: ts(4)
        },
        %Event.EffectApplicationStarted{
          id: event_id(),
          workflow_id: @workflow_id,
          timestamp: ts(5)
        },
        %Event.EffectApplied{
          id: event_id(),
          workflow_id: @workflow_id,
          intent: intent(),
          result: :fake_result,
          timestamp: ts(6)
        },
        %Event.EffectsApplied{
          id: event_id(),
          workflow_id: @workflow_id,
          intent_results: [{intent(), :fake_result}],
          timestamp: ts(6)
        },
        %Event.ArtifactProduced{
          id: event_id(),
          workflow_id: @workflow_id,
          intent: intent(),
          result: :fake_result,
          artifact: :fake_artifact,
          timestamp: ts(7)
        },
        %Event.ArtifactsProduced{
          id: event_id(),
          workflow_id: @workflow_id,
          artifacts: [:fake_artifact],
          timestamp: ts(7)
        },
        %Event.WorkflowResultAssembled{
          id: event_id(),
          workflow_id: @workflow_id,
          result: result,
          timestamp: ts(8)
        },
        %Event.WorkflowCompleted{
          id: event_id(),
          workflow_id: @workflow_id,
          timestamp: ts(9)
        }
      ]

      w = WorkflowReducer.replay(events)

      assert w.status == :completed
      assert w.id == @workflow_id
      assert w.task_id == @task_id
      assert w.proposal == proposal()
      assert w.result == result
      assert w.created_at == ts(0)
      assert w.started_at == ts(1)
      assert w.completed_at == ts(9)
      assert w.updated_at == ts(9)
      assert w.error == nil

      # Replay is a pure fold: same log in, same workflow out.
      assert WorkflowReducer.replay(events) == w
    end

    test "folds a plan-mode stream to :planned" do
      events = [
        genesis(:plan),
        %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: @workflow_id,
          timestamp: ts(1)
        },
        %Event.ProposalProduced{
          id: event_id(),
          workflow_id: @workflow_id,
          proposal: proposal(),
          timestamp: ts(2)
        },
        %Event.ProposalValidated{
          id: event_id(),
          workflow_id: @workflow_id,
          proposal: proposal(),
          timestamp: ts(3)
        },
        %Event.WorkflowCompleted{
          id: event_id(),
          workflow_id: @workflow_id,
          timestamp: ts(4)
        }
      ]

      w = WorkflowReducer.replay(events)

      assert w.status == :planned
      assert w.mode == :plan
      assert w.proposal == proposal()
      assert w.result == nil
      assert w.completed_at == ts(4)
    end
  end
end
