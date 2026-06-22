defmodule Current.PlanModeTest do
  use ExUnit.Case, async: false

  alias Current.Request

  @receive_timeout 5_000

  test "plan mode with a valid proposal completes as :planned without approval or effects" do
    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self())

    workflow =
      receive do
        {:workflow_created, ^task_id, w} -> w
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    receive do
      {:proposal_production_started, ^task_id, _} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_production_started")
    end

    proposal =
      receive do
        {:proposal_produced, ^task_id, _, p} -> p
      after
        @receive_timeout -> flunk("did not receive proposal_produced")
      end

    receive do
      {:proposal_validated, ^task_id, _, _} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_validated")
    end

    receive do
      {:workflow_completed, ^task_id, completed_workflow} ->
        assert completed_workflow.status == :planned
        assert completed_workflow.proposal.id == proposal.id
        assert completed_workflow.result == nil
        assert completed_workflow.completed_at != nil
    after
      @receive_timeout -> flunk("did not receive workflow_completed")
    end

    {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned
    assert final.mode == :plan

    events = Current.EventStore.list_by_workflow_id(workflow.id)

    assert [
             %Current.Event.WorkflowCreated{},
             %Current.Event.ProposalProductionStarted{},
             %Current.Event.ProposalProduced{},
             %Current.Event.ProposalValidated{},
             %Current.Event.WorkflowCompleted{}
           ] = events

    refute_receive {:proposal_approved, ^task_id, _}, 200
    refute_receive {:effects_applied, ^task_id, _, _}, 200
    refute_receive {:artifact_produced, ^task_id, _, _}, 200
    refute_receive {:workflow_result_assembled, ^task_id, _, _}, 200
  end

  test "plan mode with a proposal that would fail on effect application still completes as :planned" do
    # WouldFailOnApplyProposalBuilder proposes WriteFile to an already-existing path.
    # IntentValidator does not check WriteFile, so validation passes.
    # In :apply mode the effect applicator would fail with "file already exists".
    # In :plan mode effects are never attempted, so the workflow completes as :planned.
    :persistent_term.put(:proposal_builder, Current.WouldFailOnApplyProposalBuilder)
    on_exit(fn -> :persistent_term.put(:proposal_builder, Current.ProposalBuilder) end)

    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self())

    receive do
      {:workflow_created, ^task_id, _} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_created")
    end

    receive do
      {:proposal_production_started, ^task_id, _} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_production_started")
    end

    receive do
      {:proposal_produced, ^task_id, _, _} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_produced")
    end

    receive do
      {:proposal_validated, ^task_id, _, _} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_validated")
    end

    receive do
      {:workflow_completed, ^task_id, completed_workflow} ->
        assert completed_workflow.status == :planned
        assert completed_workflow.result == nil
    after
      @receive_timeout ->
        flunk("plan mode should complete even when proposal would fail on apply")
    end

    {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned

    refute_receive {:effect_failed, ^task_id, _, _}, 200
    refute_receive {:workflow_failed, ^task_id, _}, 200
  end

  test "invalid mode transitions workflow through :invalid_mode to :failed without planning" do
    req = %Request{input: "add email validation", context: %{}, mode: :simulate}
    {:ok, task_id} = Current.submit_task(req, self())

    workflow =
      receive do
        {:workflow_created, ^task_id, w} -> w
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    receive do
      {:mode_invalid, ^task_id, _invalid_workflow, rejected_mode} ->
        assert rejected_mode == :simulate
    after
      @receive_timeout -> flunk("did not receive mode_invalid")
    end

    receive do
      {:workflow_failed, ^task_id, failed_workflow} ->
        assert failed_workflow.status == :failed
        assert failed_workflow.error =~ "invalid mode"
        assert failed_workflow.proposal == nil
        assert failed_workflow.result == nil
    after
      @receive_timeout -> flunk("did not receive workflow_failed")
    end

    {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :failed

    events = Current.EventStore.list_by_workflow_id(workflow.id)

    assert [
             %Current.Event.WorkflowCreated{},
             %Current.Event.ModeInvalid{} = mode_invalid_event,
             %Current.Event.WorkflowFailed{}
           ] = events

    assert mode_invalid_event.mode == :simulate

    refute_receive {:proposal_production_started, ^task_id, _}, 200
    refute_receive {:workflow_completed, ^task_id, _}, 200
  end
end
