defmodule Current.PlanModeTest do
  use ExUnit.Case, async: false

  alias Current.{Event, Request}

  @receive_timeout 5_000

  test "plan mode with a valid proposal completes as :planned" do
    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self(), System.tmp_dir!())

    receive do
      {:workflow_completed, %Event.WorkflowCompleted{}} ->
        :ok
    after
      @receive_timeout ->
        flunk("did not receive workflow_completed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned
    assert final.mode == :plan
    assert final.result == nil
  end

  test "plan mode with a proposal that would fail on effect application still completes as :planned" do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)

    :ok =
      Application.put_env(:current, :proposal_builder, Current.WouldFailOnApplyProposalBuilder)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
    end)

    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self(), System.tmp_dir!())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{workflow_id: workflow_id}} ->
          workflow_id
      after
        @receive_timeout ->
          flunk("did not receive workflow_created")
      end

    receive do
      {:proposal_validated, %Event.ProposalValidated{workflow_id: ^workflow_id}} ->
        :ok
    after
      @receive_timeout ->
        flunk("did not receive proposal_validated")
    end

    receive do
      {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} ->
        :ok
    after
      @receive_timeout ->
        flunk("plan mode should complete even when proposal would fail on apply")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned
    assert final.result == nil

    events = Current.EventStore.list_by_workflow_id(workflow_id)

    refute Enum.any?(events, &match?(%Event.EffectApplicationStarted{}, &1))
    refute Enum.any?(events, &match?(%Event.EffectApplied{}, &1))
    refute Enum.any?(events, &match?(%Event.EffectFailed{}, &1))
    refute Enum.any?(events, &match?(%Event.WorkflowFailed{}, &1))
  end
end
