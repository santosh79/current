defmodule Current.E2E.LLMProposalTest do
  @moduledoc """
  The real proposal builder (Current.LLMProposalBuilder) end to end, with
  only the model faked: the request's model resolves to a test catalog
  client, which answers with whatever FakeLLMClient.set_response/1 was
  given. Whatever the model says, the workflow ends in a recorded outcome.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{Event, FakeLLMClient, LLMProposalBuilder}

  setup do
    use_proposal_builder(LLMProposalBuilder)
  end

  # Plan mode against this repository's own directory as the project.
  defp submit_with_response(response) do
    FakeLLMClient.set_response(response)
    {:ok, task_id} = Current.submit_task(request(mode: :plan), self())
    {task_id, await_workflow_created(task_id)}
  end

  defp production_error(workflow_id) do
    %Event.ProposalProductionFailed{error: error} =
      await(:proposal_production_failed, workflow_id)

    error
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

    {task_id, workflow_id} = submit_with_response({:ok, raw})

    %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)
    assert length(proposal.intents) == 2

    await(:proposal_validated, workflow_id)
    await(:workflow_completed, workflow_id)

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned
    assert final.mode == :plan
    assert final.result == nil
  end

  test "an undecodable response fails production at the decode stage, keeping the raw output" do
    {task_id, workflow_id} = submit_with_response({:ok, "not json at all {{{"})

    error = production_error(workflow_id)
    assert error.stage == :decode
    assert error.raw_output_blob_id != nil

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end

  test "a well-formed but semantically invalid response fails validation, not production" do
    raw = ~s({"intents": [{"type": "claim", "statement": "no evidence given"}]})
    {task_id, workflow_id} = submit_with_response({:ok, raw})

    await(:proposal_produced, workflow_id)

    %Event.ProposalValidationFailed{error: error} =
      await(:proposal_validation_failed, workflow_id)

    assert error.reason =~ "requires evidence"

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end

  test "a client error fails production at the connection stage" do
    {task_id, workflow_id} = submit_with_response({:error, :econnrefused})

    assert production_error(workflow_id).stage == :connection

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end

  test "a model that never answers fails production at the timeout stage" do
    put_env(:llm_proposal_timeout_ms, 100)

    {task_id, workflow_id} = submit_with_response(:hang)

    assert production_error(workflow_id).stage == :timeout

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end
end
