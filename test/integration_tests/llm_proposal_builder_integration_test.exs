defmodule Current.LLMProposalBuilderIntegrationTest do
  @moduledoc """
  M1's actual acceptance criterion: LLMProposalBuilder wired in as the
  live :proposal_builder, driven through the real public API
  (Current.submit_task/2), not called directly. Unit tests already cover
  ProposalDecoder, IntentValidator, and LLMProposalBuilder's own
  stage-classification in isolation -- this is the one place that proves
  they're wired together correctly end to end, the same way
  plan_mode_test.exs does for the hardcoded builder.
  """

  use ExUnit.Case, async: false

  alias Current.{Event, FakeLLMClient, LLMProposalBuilder, Request}

  @receive_timeout 5_000

  setup do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)
    previous_client = Application.fetch_env!(:current, :llm_client)

    :ok = Application.put_env(:current, :proposal_builder, LLMProposalBuilder)
    :ok = Application.put_env(:current, :llm_client, FakeLLMClient)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
      :ok = Application.put_env(:current, :llm_client, previous_client)
    end)

    :ok
  end

  test "a well-formed model response completes as :planned" do
    raw = ~s({
      "justification": "add email validation",
      "intents": [
        {"ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"]},
        {"type": "claim", "statement": "tests pass",
         "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}}
      ]
    })

    FakeLLMClient.set_response({:ok, raw})

    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{workflow_id: workflow_id}} -> workflow_id
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    proposal =
      receive do
        {:proposal_produced,
         %Event.ProposalProduced{workflow_id: ^workflow_id, proposal: proposal}} ->
          proposal
      after
        @receive_timeout -> flunk("did not receive proposal_produced")
      end

    assert length(proposal.intents) == 2

    receive do
      {:proposal_validated, %Event.ProposalValidated{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_validated")
    end

    receive do
      {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_completed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned
    assert final.mode == :plan
    assert final.result == nil
  end

  test "an undecodable model response fails as ProposalProductionFailed with stage: :decode, not a crash" do
    FakeLLMClient.set_response({:ok, "not json at all {{{"})

    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{workflow_id: workflow_id}} -> workflow_id
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    error =
      receive do
        {:proposal_production_failed,
         %Event.ProposalProductionFailed{workflow_id: ^workflow_id, error: error}} ->
          error
      after
        @receive_timeout -> flunk("did not receive proposal_production_failed")
      end

    assert error.stage == :decode
    assert error.raw_output_blob_id != nil

    receive do
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_failed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :failed
  end

  test "a well-formed but semantically invalid response fails as ProposalValidationFailed, not ProposalProductionFailed" do
    raw = ~s({"intents": [{"type": "claim", "statement": "no evidence given"}]})
    FakeLLMClient.set_response({:ok, raw})

    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{workflow_id: workflow_id}} -> workflow_id
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    receive do
      {:proposal_produced, %Event.ProposalProduced{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive proposal_produced")
    end

    receive do
      {:proposal_validation_failed,
       %Event.ProposalValidationFailed{workflow_id: ^workflow_id, error: error}} ->
        assert error.reason =~ "requires evidence"
    after
      @receive_timeout -> flunk("did not receive proposal_validation_failed")
    end

    receive do
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_failed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :failed
  end

  test "a client connection error fails as ProposalProductionFailed with stage: :connection" do
    FakeLLMClient.set_response({:error, :econnrefused})

    req = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{workflow_id: workflow_id}} -> workflow_id
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    receive do
      {:proposal_production_failed,
       %Event.ProposalProductionFailed{workflow_id: ^workflow_id, error: error}} ->
        assert error.stage == :connection
    after
      @receive_timeout -> flunk("did not receive proposal_production_failed")
    end

    receive do
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_failed")
    end

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :failed
  end
end
