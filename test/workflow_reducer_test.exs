defmodule Current.WorkflowReducerTest do
  use ExUnit.Case, async: true

  alias Current.{Event, Id, Intent, Proposal, Workflow, WorkflowReducer, WorkflowResult}
  alias Current.Error.ValidationError

  setup do
    {:ok,
     fixture: %{
       workflow_id: Id.generate(),
       task_id: Id.generate(),
       proposal_id: Id.generate(),
       intent_id: Id.generate(),
       result_id: Id.generate(),
       t0: DateTime.utc_now()
     }}
  end

  defp ts(fixture, seconds), do: DateTime.add(fixture.t0, seconds, :second)

  defp event_id, do: Id.generate()

  defp genesis(fixture, mode \\ :apply) do
    %Event.WorkflowCreated{
      id: event_id(),
      workflow_id: fixture.workflow_id,
      task_id: fixture.task_id,
      mode: mode,
      timestamp: ts(fixture, 0)
    }
  end

  defp proposal(fixture) do
    %Proposal{
      id: fixture.proposal_id,
      workflow_id: fixture.workflow_id,
      intents: [intent(fixture)]
    }
  end

  defp intent(fixture) do
    %Intent.RunCommand{
      id: fixture.intent_id,
      proposal_id: fixture.proposal_id,
      cmd: "echo",
      args: ["hello"]
    }
  end

  defp workflow_result(fixture) do
    %WorkflowResult{
      id: fixture.result_id,
      workflow_id: fixture.workflow_id,
      type: :result_bundle,
      intent_results: [{intent(fixture), :fake_result}],
      created_at: ts(fixture, 7)
    }
  end

  defp validating(fixture, mode \\ :apply) do
    events = [
      genesis(fixture, mode),
      %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        timestamp: ts(fixture, 1)
      },
      %Event.ProposalProduced{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        proposal: proposal(fixture),
        timestamp: ts(fixture, 2)
      }
    ]

    {:ok, ww} = WorkflowReducer.replay(events)
    ww
  end

  defp waiting_for_approval(fixture, mode \\ :apply) do
    {:ok, w} =
      WorkflowReducer.apply_event(validating(fixture, mode), %Event.ProposalValidated{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        proposal: proposal(fixture),
        timestamp: ts(fixture, 3)
      })

    w
  end

  defp approved(fixture, mode \\ :apply) do
    {:ok, w} =
      WorkflowReducer.apply_event(waiting_for_approval(fixture, mode), proposal_approved(fixture))

    w
  end

  defp applying(fixture, mode \\ :apply) do
    {:ok, w} =
      WorkflowReducer.apply_event(approved(fixture, mode), effect_application_started(fixture))

    w
  end

  defp assembling_result(fixture, mode) do
    {:ok, w} =
      WorkflowReducer.apply_event(applying(fixture, mode), %Event.WorkflowResultAssembled{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        result: workflow_result(fixture),
        timestamp: ts(fixture, 7)
      })

    w
  end

  defp proposal_approved(fixture, timestamp \\ nil) do
    timestamp = timestamp || ts(fixture, 4)

    %Event.ProposalApproved{
      id: event_id(),
      workflow_id: fixture.workflow_id,
      proposal_id: fixture.proposal_id,
      metadata: %{reviewed_by: :test},
      timestamp: timestamp
    }
  end

  defp proposal_rejected(fixture, timestamp \\ nil) do
    timestamp = timestamp || ts(fixture, 4)

    %Event.ProposalRejected{
      id: event_id(),
      workflow_id: fixture.workflow_id,
      proposal_id: fixture.proposal_id,
      metadata: %{reviewed_by: :test},
      timestamp: timestamp
    }
  end

  defp effect_application_started(fixture, timestamp \\ nil) do
    timestamp = timestamp || ts(fixture, 5)

    %Event.EffectApplicationStarted{
      id: event_id(),
      workflow_id: fixture.workflow_id,
      timestamp: timestamp
    }
  end

  describe "genesis (WorkflowCreated)" do
    test "builds the initial workflow entirely from the event's facts", %{fixture: fixture} do
      {:ok, w} = WorkflowReducer.apply_event(nil, genesis(fixture))

      assert %Workflow{} = w
      assert w.id == fixture.workflow_id
      assert w.task_id == fixture.task_id
      assert w.mode == :apply
      assert w.status == :created
      assert w.created_at == ts(fixture, 0)
      assert w.updated_at == ts(fixture, 0)
      assert w.proposal == nil
      assert w.result == nil
      assert w.events == []
      assert w.started_at == nil
      assert w.completed_at == nil
      assert w.error == nil
    end

    test "is deterministic — the same event always yields the same workflow", %{fixture: fixture} do
      event = genesis(fixture)

      assert WorkflowReducer.apply_event(nil, event) ==
               WorkflowReducer.apply_event(nil, event)
    end

    test "carries the mode through, including :plan", %{fixture: fixture} do
      {:ok, w} = WorkflowReducer.apply_event(nil, genesis(fixture, :plan))
      assert w.mode == :plan
    end
  end

  describe "planning" do
    test "ProposalProductionStarted moves to :planning and starts the clock", %{fixture: fixture} do
      {:ok, w0} = WorkflowReducer.apply_event(nil, genesis(fixture))

      event = %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        timestamp: ts(fixture, 1)
      }

      {:ok, w} = WorkflowReducer.apply_event(w0, event)

      assert w.status == :planning
      assert w.started_at == ts(fixture, 1)
      assert w.updated_at == ts(fixture, 1)
      assert w.created_at == ts(fixture, 0)
    end

    test "ModeInvalid moves to :invalid_mode", %{fixture: fixture} do
      {:ok, w0} = WorkflowReducer.apply_event(nil, genesis(fixture, :simulate))

      event = %Event.ModeInvalid{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        mode: :simulate,
        timestamp: ts(fixture, 1)
      }

      {:ok, w} = WorkflowReducer.apply_event(w0, event)

      assert w.status == :invalid_mode
      assert w.updated_at == ts(fixture, 1)
    end

    test "ProposalProduced records the proposal and moves to :validating", %{fixture: fixture} do
      w = validating(fixture)

      assert w.status == :validating
      assert w.proposal == proposal(fixture)
      assert w.updated_at == ts(fixture, 2)
    end

    test "ProposalProductionFailed records the reason and moves to :proposal_production_failed",
         %{fixture: fixture} do
      {:ok, w0} = WorkflowReducer.apply_event(nil, genesis(fixture))

      {:ok, w1} =
        WorkflowReducer.apply_event(w0, %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 1)
        })

      {:ok, w} =
        WorkflowReducer.apply_event(w1, %Event.ProposalProductionFailed{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          reason: "timed out",
          timestamp: ts(fixture, 2)
        })

      assert w.status == :proposal_production_failed
      assert w.error == "timed out"
      assert w.updated_at == ts(fixture, 2)
    end
  end

  describe "validation" do
    test "ProposalValidated moves to :waiting_for_approval", %{fixture: fixture} do
      w = waiting_for_approval(fixture)

      assert w.status == :waiting_for_approval
      assert w.proposal == proposal(fixture)
      assert w.updated_at == ts(fixture, 3)
    end

    test "ProposalValidationFailed extracts the reason from a ValidationError", %{
      fixture: fixture
    } do
      error = %ValidationError{intent_id: nil, reason: "path does not exist"}

      event = %Event.ProposalValidationFailed{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        proposal: proposal(fixture),
        error: error,
        timestamp: ts(fixture, 3)
      }

      {:ok, w} = WorkflowReducer.apply_event(validating(fixture), event)

      assert w.status == :validation_failed
      assert w.error == "path does not exist"
      assert w.updated_at == ts(fixture, 3)
    end

    test "ProposalValidationFailed tolerates a bare error term", %{fixture: fixture} do
      event = %Event.ProposalValidationFailed{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        proposal: proposal(fixture),
        error: :inscrutable,
        timestamp: ts(fixture, 3)
      }

      {:ok, w} = WorkflowReducer.apply_event(validating(fixture), event)

      assert w.status == :validation_failed
      assert w.error == :inscrutable
    end
  end

  describe "approval" do
    test "ProposalApproved moves to :approved", %{fixture: fixture} do
      {:ok, w} =
        WorkflowReducer.apply_event(waiting_for_approval(fixture), proposal_approved(fixture))

      assert w.status == :approved
      assert w.updated_at == ts(fixture, 4)
    end

    test "ProposalRejected moves to :rejected", %{fixture: fixture} do
      {:ok, w} =
        WorkflowReducer.apply_event(waiting_for_approval(fixture), proposal_rejected(fixture))

      assert w.status == :rejected
      assert w.updated_at == ts(fixture, 4)
      assert w.completed_at == nil
    end
  end

  describe "effect application" do
    test "EffectApplicationStarted moves to :applying", %{fixture: fixture} do
      {:ok, w} =
        WorkflowReducer.apply_event(approved(fixture), effect_application_started(fixture))

      assert w.status == :applying
      assert w.updated_at == ts(fixture, 5)
    end

    test "fact-only events leave the workflow untouched", %{fixture: fixture} do
      w = applying(fixture)

      facts = [
        %Event.EffectApplied{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          intent: intent(fixture),
          result: :fake_result,
          timestamp: ts(fixture, 6)
        },
        %Event.EffectApplicationComplete{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          intent_results: [{intent(fixture), :fake_result}],
          timestamp: ts(fixture, 6)
        },
        %Event.EffectFailed{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          intent: intent(fixture),
          reason: "boom",
          timestamp: ts(fixture, 6)
        }
      ]

      Enum.each(facts, fn fact ->
        {:ok, ww} = WorkflowReducer.apply_event(w, fact)
        assert ww == w
      end)
    end
  end

  describe "result assembly and terminal states" do
    test "WorkflowResultAssembled records the result and moves to :assembling_result", %{
      fixture: fixture
    } do
      result = workflow_result(fixture)

      result_event = %Event.WorkflowResultAssembled{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        result: result,
        timestamp: ts(fixture, 7)
      }

      {:ok, w} = WorkflowReducer.apply_event(applying(fixture), result_event)

      assert w.status == :assembling_result
      assert w.result == result
      assert w.updated_at == ts(fixture, 7)
    end

    test "WorkflowCompleted lands on :completed for apply mode", %{fixture: fixture} do
      completed_event = %Event.WorkflowCompleted{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        timestamp: ts(fixture, 8)
      }

      {:ok, w} = WorkflowReducer.apply_event(assembling_result(fixture, :apply), completed_event)

      assert w.status == :completed
      assert w.completed_at == ts(fixture, 8)
      assert w.updated_at == ts(fixture, 8)
    end

    test "WorkflowCompleted lands on :planned for plan mode",
         %{fixture: fixture} do
      event = %Event.WorkflowCompleted{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        timestamp: ts(fixture, 4)
      }

      {:ok, w} =
        WorkflowReducer.apply_event(
          waiting_for_approval(fixture, :plan),
          event
        )

      assert w.status == :planned
    end

    test "WorkflowFailed records the reason and moves to :failed", %{fixture: fixture} do
      {:ok, w0} = WorkflowReducer.apply_event(nil, genesis(fixture, :simulate))

      mode_invalid_event = %Event.ModeInvalid{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        mode: :simulate,
        timestamp: ts(fixture, 1)
      }

      {:ok, w1} = WorkflowReducer.apply_event(w0, mode_invalid_event)

      event = %Event.WorkflowFailed{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        reason: "invalid mode: :simulate",
        timestamp: ts(fixture, 2)
      }

      {:ok, w} = WorkflowReducer.apply_event(w1, event)

      assert w.status == :failed
      assert w.error == "invalid mode: :simulate"
      assert w.updated_at == ts(fixture, 2)
    end
  end

  describe "invalid transitions" do
    test "an illegal transition is reported as {:error, {:invalid_transition, status, event_module}}",
         %{fixture: fixture} do
      {:ok, w0} = WorkflowReducer.apply_event(nil, genesis(fixture))

      bogus_event = %Event.WorkflowCompleted{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        timestamp: ts(fixture, 1)
      }

      assert {:error, {:invalid_transition, :created, Event.WorkflowCompleted}} =
               WorkflowReducer.apply_event(w0, bogus_event)
    end

    test "an event with no existing workflow is reported as {:error, {:invalid_transition, nil}}",
         %{fixture: fixture} do
      bogus_event = %Event.ProposalProductionStarted{
        id: event_id(),
        workflow_id: fixture.workflow_id,
        timestamp: ts(fixture, 0)
      }

      assert {:error, {:invalid_transition, nil, Current.Event.ProposalProductionStarted}} =
               WorkflowReducer.apply_event(nil, bogus_event)
    end
  end

  describe "replay/1" do
    test "returns nil for an empty stream" do
      assert WorkflowReducer.replay([]) == {:ok, nil}
    end

    test "stops at the first illegal transition and returns {:error, reason}", %{fixture: fixture} do
      events = [
        genesis(fixture),
        %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 1)
        },
        %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 2)
        }
      ]

      assert {:error, {:invalid_transition, :planning, Event.ProposalProductionStarted}} =
               Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, workflow} ->
                 case WorkflowReducer.apply_event(workflow, event) do
                   {:ok, next} -> {:cont, {:ok, next}}
                   {:error, reason} -> {:halt, {:error, reason}}
                 end
               end)
    end

    test "folds a full happy-path stream to :completed, deterministically", %{fixture: fixture} do
      result = workflow_result(fixture)

      events = [
        genesis(fixture),
        %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 1)
        },
        %Event.ProposalProduced{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          proposal: proposal(fixture),
          timestamp: ts(fixture, 2)
        },
        %Event.ProposalValidated{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          proposal: proposal(fixture),
          timestamp: ts(fixture, 3)
        },
        %Event.ProposalApproved{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          proposal_id: fixture.proposal_id,
          metadata: %{reviewed_by: :test},
          timestamp: ts(fixture, 4)
        },
        %Event.EffectApplicationStarted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 5)
        },
        %Event.EffectApplied{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          intent: intent(fixture),
          result: :fake_result,
          timestamp: ts(fixture, 6)
        },
        %Event.EffectApplicationComplete{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          intent_results: [{intent(fixture), :fake_result}],
          timestamp: ts(fixture, 6)
        },
        %Event.WorkflowResultAssembled{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          result: result,
          timestamp: ts(fixture, 8)
        },
        %Event.WorkflowCompleted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 9)
        }
      ]

      {:ok, w} = WorkflowReducer.replay(events)

      assert w.status == :completed
      assert w.id == fixture.workflow_id
      assert w.task_id == fixture.task_id
      assert w.proposal == proposal(fixture)
      assert w.result == result
      assert w.created_at == ts(fixture, 0)
      assert w.started_at == ts(fixture, 1)
      assert w.completed_at == ts(fixture, 9)
      assert w.updated_at == ts(fixture, 9)
      assert w.error == nil

      assert WorkflowReducer.replay(events) == {:ok, w}
    end

    test "folds a plan-mode stream to :planned", %{fixture: fixture} do
      events = [
        genesis(fixture, :plan),
        %Event.ProposalProductionStarted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 1)
        },
        %Event.ProposalProduced{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          proposal: proposal(fixture),
          timestamp: ts(fixture, 2)
        },
        %Event.ProposalValidated{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          proposal: proposal(fixture),
          timestamp: ts(fixture, 3)
        },
        %Event.WorkflowCompleted{
          id: event_id(),
          workflow_id: fixture.workflow_id,
          timestamp: ts(fixture, 4)
        }
      ]

      {:ok, w} = WorkflowReducer.replay(events)

      assert w.status == :planned
      assert w.mode == :plan
      assert w.proposal == proposal(fixture)
      assert w.result == nil
      assert w.completed_at == ts(fixture, 4)
    end
  end

  @all_statuses [
    :created,
    :planning,
    :validating,
    :waiting_for_approval,
    :validation_failed,
    :approved,
    :applying,
    :assembling_result,
    :completed,
    :planned,
    :invalid_mode,
    :rejected,
    :failed
  ]

  defp bare_workflow(fixture, status, mode \\ :apply) do
    %Workflow{
      id: fixture.workflow_id,
      task_id: fixture.task_id,
      status: status,
      mode: mode,
      created_at: ts(fixture, 0)
    }
  end

  @transitions [
    {Event.ProposalProductionStarted, [:created]},
    {Event.ModeInvalid, [:created]},
    {Event.ProposalProduced, [:planning]},
    {Event.ProposalProductionFailed, [:planning]},
    {Event.ProposalValidated, [:validating]},
    {Event.ProposalValidationFailed, [:validating]},
    {Event.ProposalApproved, [:waiting_for_approval]},
    {Event.ProposalRejected, [:waiting_for_approval]},
    {Event.EffectApplicationStarted, [:approved]},
    {Event.EffectApplied, [:applying]},
    {Event.EffectApplicationComplete, [:applying]},
    {Event.EffectFailed, [:applying]},
    {Event.WorkflowResultAssembled, [:applying]},
    {Event.WorkflowCompleted, [:assembling_result]},
    {Event.WorkflowFailed,
     [:invalid_mode, :validation_failed, :applying, :proposal_production_failed]}
  ]

  describe "transition legality: WorkflowCreated" do
    test "is legal only when there is no existing workflow", %{fixture: fixture} do
      event = struct(Event.WorkflowCreated, workflow_id: fixture.workflow_id)
      assert {:ok, _} = WorkflowReducer.apply_event(nil, event)

      Enum.each(@all_statuses, fn status ->
        assert {:error, {:invalid_transition, ^status, Event.WorkflowCreated}} =
                 WorkflowReducer.apply_event(bare_workflow(fixture, status), event),
               "expected WorkflowCreated to be illegal from #{status}"
      end)
    end
  end

  describe "transition legality: every other lifecycle event" do
    test "is illegal when there is no existing workflow", %{fixture: _fixture} do
      Enum.each(@transitions, fn {mod, _allowed} ->
        assert {:error, {:invalid_transition, nil, _event}} =
                 WorkflowReducer.apply_event(nil, struct(mod)),
               "expected #{inspect(mod)} to be illegal from nil"
      end)
    end
  end

  Enum.each(@transitions, fn {mod, allowed} ->
    test "#{inspect(mod)} is legal from exactly #{inspect(allowed)} at mode: :apply", %{
      fixture: fixture
    } do
      event = struct(unquote(mod), workflow_id: fixture.workflow_id)
      allowed = unquote(allowed)

      Enum.each(allowed, fn status ->
        assert {:ok, _} = WorkflowReducer.apply_event(bare_workflow(fixture, status), event),
               "expected #{unquote(inspect(mod))} to be LEGAL from #{status}"
      end)

      Enum.each(@all_statuses -- allowed, fn status ->
        assert {:error, {:invalid_transition, ^status, unquote(mod)}} =
                 WorkflowReducer.apply_event(bare_workflow(fixture, status), event),
               "expected #{unquote(inspect(mod))} to be ILLEGAL from #{status}"
      end)
    end
  end)

  describe "transition legality: mode independence elsewhere" do
    test "every rule above except WorkflowCompleted-from-:waiting_for_approval is mode-independent",
         %{fixture: fixture} do
      Enum.each(@transitions, fn {mod, allowed} ->
        Enum.each(allowed, fn status ->
          event = struct(mod, workflow_id: fixture.workflow_id)

          apply_ok? =
            match?(
              {:ok, _},
              WorkflowReducer.apply_event(bare_workflow(fixture, status, :apply), event)
            )

          plan_ok? =
            match?(
              {:ok, _},
              WorkflowReducer.apply_event(bare_workflow(fixture, status, :plan), event)
            )

          assert apply_ok? == plan_ok?,
                 "expected #{inspect(mod)} from #{status} to be legal/illegal independent of mode"
        end)
      end)
    end
  end

  describe "transition legality: plan mode's WorkflowCompleted shortcut" do
    test "WorkflowCompleted from :waiting_for_approval is legal only in :plan mode", %{
      fixture: fixture
    } do
      event = struct(Event.WorkflowCompleted, workflow_id: fixture.workflow_id)

      assert {:ok, w} =
               WorkflowReducer.apply_event(
                 bare_workflow(fixture, :waiting_for_approval, :plan),
                 event
               )

      assert w.status == :planned

      assert {:error, {:invalid_transition, :waiting_for_approval, Event.WorkflowCompleted}} =
               WorkflowReducer.apply_event(
                 bare_workflow(fixture, :waiting_for_approval, :apply),
                 event
               )
    end
  end

  describe "transition legality: workflow_id mismatch" do
    test "an event addressed to a different workflow is rejected regardless of status or event type",
         %{fixture: fixture} do
      workflow_id = fixture.workflow_id
      other_workflow_id = Id.generate()

      Enum.each(@transitions, fn {mod, allowed} ->
        Enum.each(allowed, fn status ->
          event = struct(mod, workflow_id: other_workflow_id)

          assert {:error, {:workflow_id_mismatch, ^workflow_id, ^other_workflow_id}} =
                   WorkflowReducer.apply_event(bare_workflow(fixture, status), event),
                 "expected #{inspect(mod)} addressed to a different workflow to be rejected " <>
                   "even though #{status} is otherwise a legal predecessor"
        end)
      end)
    end
  end

  describe "transition legality: completeness" do
    test "every lifecycle event module has a defined transition rule" do
      covered = Enum.map(@transitions, fn {mod, _} -> mod end) ++ [Event.WorkflowCreated]

      assert Enum.sort(covered) == Enum.sort(Event.lifecycle_modules()),
             "Event.lifecycle_modules/0 and this test's @transitions table have drifted apart"
    end

    test "this test's @all_statuses covers every known workflow status" do
      assert Enum.sort(@all_statuses) == Enum.sort(Workflow.statuses()),
             "Current.Workflow.statuses/0 and this test's @all_statuses have drifted apart"
    end
  end
end
