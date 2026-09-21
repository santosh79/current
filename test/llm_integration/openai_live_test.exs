defmodule Current.LLMIntegration.OpenAILiveTest do
  use ExUnit.Case, async: false

  alias Current.{LLMProposalBuilder, Proposal, Request}

  @moduletag :live_llm

  setup do
    previous_client = Application.fetch_env!(:current, :llm_client)

    on_exit(fn ->
      :ok = Application.put_env(:current, :llm_client, previous_client)
    end)

    :ok
  end

  test "OpenAI produces a proposal that Current can decode" do
    case System.get_env("OPENAI_API_KEY") in [nil, ""] do
      true -> flunk("OPENAI_API_KEY must be set to run live LLM tests")
      _ -> :ok
    end

    request = %Request{
      input: "Produce a report saying that the live LLM integration test succeeded.",
      context: %{},
      mode: :plan
    }

    workflow_id = Current.Id.generate()

    assert {:ok, %Proposal{} = proposal, raw_output_blob_id} =
             LLMProposalBuilder.build(
               request,
               workflow_id,
               Current.LLMClient.OpenAI
             )

    assert proposal.workflow_id == workflow_id
    assert proposal.intents != []

    assert {:ok, raw_output} =
             Current.BlobStore.read(raw_output_blob_id)

    assert is_binary(raw_output)
    assert byte_size(raw_output) > 0
  end
end
