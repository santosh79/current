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
    previous_builder = Application.fetch_env!(:current, :proposal_builder)
    :ok = Application.put_env(:current, :proposal_builder, Current.MultiIntentProposalBuilder)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
    end)

    {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

    assert length(proposal.intents) == 5
    proposal_intent_ids = Enum.map(proposal.intents, & &1.id)

    approve(proposal)

    receive do
      {:effect_application_complete,
       %Event.EffectApplicationComplete{workflow_id: ^workflow_id, intent_results: intent_results}} ->
        assert length(intent_results) == 5

        {_glob_intent, glob_result} =
          Enum.find(intent_results, fn {intent, _result} ->
            match?(%Current.Intent.Glob{}, intent)
          end)

        assert %Current.EffectResult.Glob{} = glob_result
        matches = fetch_matches(glob_result.matches_artifact_id)
        assert length(matches) == 2

        {_grep_intent, grep_result} =
          Enum.find(intent_results, fn {intent, _result} ->
            match?(%Current.Intent.Grep{}, intent)
          end)

        assert %Current.EffectResult.Grep{} = grep_result
        matches = fetch_matches(grep_result.matches_artifact_id)
        assert length(matches) == 1
        assert hd(matches).text =~ "Signup"
    after
      @receive_timeout ->
        flunk("did not receive effect_application_complete")
    end

    receive do
      {:workflow_result_assembled,
       %Event.WorkflowResultAssembled{workflow_id: ^workflow_id, result: result}} ->
        assert length(result.intent_results) == 5

        assert Enum.map(result.intent_results, fn {intent, _result} -> intent.id end)
               |> Enum.sort() == Enum.sort(proposal_intent_ids)
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
    assert length(final.result.intent_results) == 5
  end

  test "run_command output is stored as content-addressed artifacts and referenced by the workflow artifact" do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)
    :ok = Application.put_env(:current, :proposal_builder, Current.RunCommandProposalBuilder)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
    end)

    {:ok, _task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
    approve(proposal)

    result =
      receive do
        {:effect_application_complete,
         %Event.EffectApplicationComplete{
           workflow_id: ^workflow_id,
           intent_results: [{%Current.Intent.RunCommand{}, result}]
         }} ->
          result
      after
        @receive_timeout ->
          flunk("did not receive effect_application_complete")
      end

    assert result.stdout_artifact_id != result.stderr_artifact_id
  end

  test "effect application stops at the first failing intent and fails the workflow" do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)

    :ok =
      Application.put_env(:current, :proposal_builder, Current.SecondIntentFailsProposalBuilder)

    on_exit(fn ->
      :ok =
        Application.put_env(:current, :proposal_builder, previous_builder)
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

    refute Enum.any?(events, &match?(%Event.EffectApplicationComplete{}, &1))
    refute Enum.any?(events, &match?(%Event.WorkflowResultAssembled{}, &1))
    refute Enum.any?(events, &match?(%Event.WorkflowCompleted{}, &1))
  end

  defp fetch_matches(artifact_id) do
    {:ok, encoded} = Current.BlobStore.read(artifact_id)
    :erlang.binary_to_term(encoded)
  end
end
