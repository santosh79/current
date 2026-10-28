defmodule Current.E2E.WorkflowTest do
  @moduledoc """
  A workflow from submission to its end: plan mode, apply mode, and the
  ways it fails. Each test picks the proposal the "model" produces by
  swapping in a proposal builder from test/support.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{EffectResult, Event, Intent}
  alias Current.Error.ProposalProductionError

  defp fetch_matches(artifact_id) do
    {:ok, encoded} = Current.BlobStore.read(artifact_id)
    :erlang.binary_to_term(encoded, [:safe])
  end

  describe "plan mode" do
    test "a valid proposal completes as :planned, with no result" do
      task_id = submit!(mode: :plan)
      workflow_id = await_workflow_created(task_id)
      await(:workflow_completed, workflow_id)

      assert {:ok, final} = Current.get_workflow(task_id)
      assert final.status == :planned
      assert final.mode == :plan
      assert final.result == nil
    end

    test "a proposal that would fail when applied still completes: nothing is applied" do
      use_proposal_builder(Current.WouldFailOnApplyProposalBuilder)

      task_id = submit!(mode: :plan)
      workflow_id = await_workflow_created(task_id)
      await(:proposal_validated, workflow_id)
      await(:workflow_completed, workflow_id)

      assert {:ok, final} = Current.get_workflow(task_id)
      assert final.status == :planned
      assert final.result == nil

      events = events(workflow_id)
      refute any?(events, Event.EffectApplicationStarted)
      refute any?(events, Event.EffectApplied)
      refute any?(events, Event.EffectFailed)
      refute any?(events, Event.WorkflowFailed)
    end
  end

  describe "apply mode" do
    test "a five-intent proposal produces one result per intent and completes" do
      use_proposal_builder(Current.MultiIntentProposalBuilder)

      {task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
      assert length(proposal.intents) == 5

      approve_and_apply(proposal)

      %Event.EffectApplicationComplete{intent_results: intent_results} =
        await(:effect_application_complete, workflow_id)

      assert length(intent_results) == 5

      {_intent, glob_result} = Enum.find(intent_results, &match?({%Intent.Glob{}, _}, &1))
      assert %EffectResult.Glob{} = glob_result
      assert length(fetch_matches(glob_result.matches_artifact_id)) == 2

      {_intent, grep_result} = Enum.find(intent_results, &match?({%Intent.Grep{}, _}, &1))
      assert %EffectResult.Grep{} = grep_result
      assert [match] = fetch_matches(grep_result.matches_artifact_id)
      assert match.text =~ "Signup"

      %Event.WorkflowResultAssembled{result: result} =
        await(:workflow_result_assembled, workflow_id)

      assert result.intent_results |> Enum.map(fn {intent, _} -> intent.id end) |> Enum.sort() ==
               proposal.intents |> Enum.map(& &1.id) |> Enum.sort()

      await(:workflow_completed, workflow_id)

      assert {:ok, final} = Current.get_workflow(task_id)
      assert final.status == :completed
      assert length(final.result.intent_results) == 5
    end

    test "a command's stdout and stderr are stored as separate artifacts" do
      use_proposal_builder(Current.RunCommandProposalBuilder)

      {_task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
      approve_and_apply(proposal)

      assert %Event.EffectApplicationComplete{intent_results: [{%Intent.RunCommand{}, result}]} =
               await(:effect_application_complete, workflow_id)

      assert result.stdout_artifact_id != result.stderr_artifact_id
    end

    test "effect application stops at the first failing intent and fails the workflow" do
      use_proposal_builder(Current.SecondIntentFailsProposalBuilder)

      {task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
      assert [first, second, _third] = proposal.intents

      approve_and_apply(proposal)

      assert %Event.EffectApplied{intent: %{id: applied_id}} = await(:effect_applied, workflow_id)
      assert applied_id == first.id

      assert %Event.EffectFailed{intent: %{id: failed_id}, reason: reason} =
               await(:effect_failed, workflow_id)

      assert failed_id == second.id
      assert reason =~ "already exists"

      await(:workflow_failed, workflow_id)

      assert {:ok, final} = Current.get_workflow(task_id)
      assert final.status == :failed
      assert final.result == nil

      events = events(workflow_id)
      assert Enum.count(events, &is_struct(&1, Event.EffectApplied)) == 1
      assert Enum.count(events, &is_struct(&1, Event.EffectFailed)) == 1
      refute any?(events, Event.EffectApplicationComplete)
      refute any?(events, Event.WorkflowResultAssembled)
      refute any?(events, Event.WorkflowCompleted)
    end
  end

  describe "failure before approval" do
    test "a proposal that doesn't validate fails the workflow" do
      use_proposal_builder(Current.FaultyProposalBuilder)

      task_id = submit!()
      workflow_id = await_workflow_created(task_id)
      await(:proposal_validation_failed, workflow_id)
      await(:workflow_failed, workflow_id)

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.status == :failed
      assert workflow.error == "proposal validation failed"
      assert workflow.result == nil
    end

    test "a command not on the allowlist cannot be executed" do
      use_proposal_builder(Current.RunCommandProposalBuilder)

      previous = Application.fetch_env!(:current, :allowed_commands)
      Application.put_env(:current, :allowed_commands, [])

      on_exit(fn ->
        Application.put_env(:current, :allowed_commands, previous)
      end)

      {_task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert [%Intent.RunCommand{cmd: "sh"}] = proposal.intents

      approve_and_apply(proposal)
      await_finished(workflow_id)

      assert Enum.any?(events(workflow_id), fn
               %Event.EffectFailed{reason: reason} ->
                 inspect(reason) =~ "command not allowed"

               _ ->
                 false
             end)

      refute Enum.any?(events(workflow_id), &is_struct(&1, Event.EffectApplied))
    end

    test "a proposal builder that returns an error fails the workflow, with its reason" do
      use_proposal_builder(Current.ErrorReturningProposalBuilder)

      task_id = submit!()
      workflow_id = await_workflow_created(task_id)

      %Event.ProposalProductionFailed{error: error} =
        await(:proposal_production_failed, workflow_id)

      await(:workflow_failed, workflow_id)

      reason = ProposalProductionError.message(error)
      assert reason =~ "rate_limited"

      assert {:ok, %{status: :failed, error: ^reason, result: nil}} =
               Current.get_workflow(task_id)
    end
  end
end
