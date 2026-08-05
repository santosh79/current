defmodule Current.WorkflowExecutionTest do
  use ExUnit.Case, async: false

  alias Current.{Event, Request}

  @receive_timeout 5_000

  defp request do
    %Request{
      input: "add email validation to signup flow",
      context: %{}
    }
  end

  defp submit_and_await_valid_proposal do
    {:ok, task_id} = Current.submit_task(request(), self())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
          workflow_id
      after
        @receive_timeout ->
          flunk("did not receive workflow_created")
      end

    proposal =
      receive do
        {:proposal_produced,
         %Event.ProposalProduced{workflow_id: ^workflow_id, proposal: proposal}} ->
          proposal
      after
        @receive_timeout ->
          flunk("did not receive proposal_produced")
      end

    receive do
      {:proposal_validated, %Event.ProposalValidated{workflow_id: ^workflow_id}} ->
        :ok
    after
      @receive_timeout ->
        flunk("did not receive proposal_validated")
    end

    {:ok, task_id, workflow_id, proposal}
  end

  defp approve(proposal) do
    assert :ok =
             Current.review_proposal(
               proposal.id,
               {:approve, %{reviewed_by: :workflow_execution_test}}
             )
  end

  test "a five-intent proposal produces one artifact per intent and completes" do
    :persistent_term.put(:proposal_builder, Current.MultiIntentProposalBuilder)

    on_exit(fn ->
      :persistent_term.put(:proposal_builder, Current.ProposalBuilder)
    end)

    {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

    assert length(proposal.intents) == 5
    proposal_intent_ids = Enum.map(proposal.intents, & &1.id)

    approve(proposal)

    receive do
      {:effects_applied,
       %Event.EffectsApplied{workflow_id: ^workflow_id, intent_results: intent_results}} ->
        assert length(intent_results) == 5

        {_glob_intent, glob_result} =
          Enum.find(intent_results, fn {intent, _result} ->
            match?(%Current.Intent.Glob{}, intent)
          end)

        assert %Current.EffectResult.Glob{} = glob_result
        assert length(glob_result.matches) == 2

        {_grep_intent, grep_result} =
          Enum.find(intent_results, fn {intent, _result} ->
            match?(%Current.Intent.Grep{}, intent)
          end)

        assert %Current.EffectResult.Grep{} = grep_result
        assert length(grep_result.matches) == 1
        assert hd(grep_result.matches).text =~ "Signup"
    after
      @receive_timeout ->
        flunk("did not receive effects_applied")
    end

    artifacts =
      for _ <- 1..5 do
        receive do
          {:artifact_produced,
           %Event.ArtifactProduced{workflow_id: ^workflow_id, artifact: artifact}} ->
            assert artifact.intent_id in proposal_intent_ids
            assert File.exists?(artifact.storage.path)
            artifact
        after
          @receive_timeout ->
            flunk("did not receive artifact_produced")
        end
      end

    artifact_ids = Enum.map(artifacts, & &1.id)
    artifact_intent_ids = Enum.map(artifacts, & &1.intent_id)

    assert Enum.sort(artifact_intent_ids) == Enum.sort(proposal_intent_ids)
    assert length(Enum.uniq(artifact_ids)) == 5

    receive do
      {:artifacts_produced,
       %Event.ArtifactsProduced{workflow_id: ^workflow_id, artifacts: produced_artifacts}} ->
        assert Enum.sort(Enum.map(produced_artifacts, & &1.id)) == Enum.sort(artifact_ids)
    after
      @receive_timeout ->
        flunk("did not receive artifacts_produced")
    end

    receive do
      {:workflow_result_assembled,
       %Event.WorkflowResultAssembled{workflow_id: ^workflow_id, result: result}} ->
        assert Enum.sort(result.artifacts) == Enum.sort(artifact_ids)
    after
      @receive_timeout ->
        flunk("did not receive workflow_result_assembled")
    end

    receive do
      {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} ->
        :ok
    after
      @receive_timeout ->
        flunk("did not receive workflow_completed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :completed
    assert Enum.sort(final.result.artifacts) == Enum.sort(artifact_ids)
  end

  test "run_command output is stored as content-addressed artifacts and referenced by the workflow artifact" do
    :persistent_term.put(:proposal_builder, Current.RunCommandProposalBuilder)

    on_exit(fn ->
      :persistent_term.put(:proposal_builder, Current.ProposalBuilder)
    end)

    {:ok, _task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
    approve(proposal)

    result =
      receive do
        {:effects_applied,
         %Event.EffectsApplied{
           workflow_id: ^workflow_id,
           intent_results: [{%Current.Intent.RunCommand{}, result}]
         }} ->
          result
      after
        @receive_timeout ->
          flunk("did not receive effects_applied")
      end

    assert result.stdout_artifact_id != result.stderr_artifact_id

    command_artifact =
      receive do
        {:artifact_produced,
         %Event.ArtifactProduced{
           workflow_id: ^workflow_id,
           artifact: %Current.Artifact{type: :command_result} = artifact
         }} ->
          artifact
      after
        @receive_timeout ->
          flunk("did not receive command_result artifact")
      end

    assert command_artifact.metadata.stdout_artifact_id == result.stdout_artifact_id
    assert command_artifact.metadata.stderr_artifact_id == result.stderr_artifact_id
    assert command_artifact.metadata.stdout_bytes == result.stdout_bytes
    assert command_artifact.metadata.stderr_bytes == result.stderr_bytes
  end

  test "effect application stops at the first failing intent and fails the workflow" do
    :persistent_term.put(:proposal_builder, Current.SecondIntentFailsProposalBuilder)

    on_exit(fn ->
      :persistent_term.put(:proposal_builder, Current.ProposalBuilder)
      :persistent_term.put(:effect_applicator, Current.EffectApplicator)
    end)

    {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
    assert length(proposal.intents) == 3

    approve(proposal)

    receive do
      {:effect_applied, %Event.EffectApplied{workflow_id: ^workflow_id, intent: first_intent}} ->
        assert first_intent.id == Enum.at(proposal.intents, 0).id
    after
      @receive_timeout ->
        flunk("first intent was not applied")
    end

    receive do
      {:effect_failed,
       %Event.EffectFailed{workflow_id: ^workflow_id, intent: failed_intent, reason: reason}} ->
        assert failed_intent.id == Enum.at(proposal.intents, 1).id
        assert reason =~ "already exists"
    after
      @receive_timeout ->
        flunk("second intent did not fail")
    end

    receive do
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} ->
        :ok
    after
      @receive_timeout ->
        flunk("did not receive workflow_failed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :failed
    assert final.result == nil

    events = Current.EventStore.list_by_workflow_id(workflow_id)

    assert Enum.count(events, &match?(%Event.EffectApplied{}, &1)) == 1
    assert Enum.count(events, &match?(%Event.EffectFailed{}, &1)) == 1

    refute Enum.any?(events, &match?(%Event.EffectsApplied{}, &1))
    refute Enum.any?(events, &match?(%Event.ArtifactProduced{}, &1))
    refute Enum.any?(events, &match?(%Event.ArtifactsProduced{}, &1))
    refute Enum.any?(events, &match?(%Event.WorkflowResultAssembled{}, &1))
    refute Enum.any?(events, &match?(%Event.WorkflowCompleted{}, &1))
  end
end
