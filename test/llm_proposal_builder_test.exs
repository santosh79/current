defmodule Current.LLMProposalBuilderTest do
  use ExUnit.Case, async: false

  alias Current.{BlobStore, FakeLLMClient, Id, LLMProposalBuilder, Proposal, Request}
  alias Current.Error.ProposalProductionError

  defp request, do: %Request{input: "add email validation", context: %{}}

  describe "build/3 - success" do
    test "returns a decoded proposal and the raw output's blob id" do
      raw = ~s({"intents": [{"type": "run_command", "cmd": "echo"}]})
      FakeLLMClient.set_response({:ok, raw})

      assert {:ok, %Proposal{} = proposal, blob_id} =
               LLMProposalBuilder.build(request(), Id.generate(), Current.FakeLLMClient)

      assert length(proposal.intents) == 1
      assert {:ok, ^raw} = BlobStore.read(blob_id)
    end
  end

  describe "build/3 - connection failure" do
    test "wraps a client error as stage: :connection" do
      FakeLLMClient.set_response({:error, :econnrefused})

      assert {:error, %ProposalProductionError{stage: :connection, reason: :econnrefused}} =
               LLMProposalBuilder.build(request(), Id.generate(), Current.FakeLLMClient)
    end
  end

  describe "build/3 - timeout" do
    test "returns stage: :timeout when the client never responds, without hanging the test" do
      Application.put_env(:current, :llm_proposal_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:current, :llm_proposal_timeout_ms) end)

      FakeLLMClient.set_response(:hang)

      assert {:error, %ProposalProductionError{stage: :timeout}} =
               LLMProposalBuilder.build(request(), Id.generate(), Current.FakeLLMClient)
    end
  end

  describe "build/3 - decode failure" do
    test "wraps a decode error as stage: :decode and preserves the raw output's blob id" do
      raw = "not json at all {{{"
      FakeLLMClient.set_response({:ok, raw})

      assert {:error, %ProposalProductionError{stage: :decode, raw_output_blob_id: blob_id}} =
               LLMProposalBuilder.build(request(), Id.generate(), Current.FakeLLMClient)

      assert {:ok, ^raw} = BlobStore.read(blob_id)
    end

    test "an unknown intent type also surfaces as stage: :decode" do
      raw = ~s({"intents": [{"type": "teleport"}]})
      FakeLLMClient.set_response({:ok, raw})

      assert {:error, %ProposalProductionError{stage: :decode, reason: reason}} =
               LLMProposalBuilder.build(request(), Id.generate(), Current.FakeLLMClient)

      assert reason =~ "unknown intent type"
    end
  end

  describe "build/3 - a client that raises never crashes the builder" do
    defmodule RaisingClient do
      @behaviour Current.LLMClient
      @impl true
      def complete(_prompt), do: raise("client exploded")
    end

    test "surfaces as a connection-stage error, not an exception" do
      assert {:error, %ProposalProductionError{stage: :connection, reason: reason}} =
               LLMProposalBuilder.build(request(), Id.generate(), RaisingClient)

      assert reason =~ "client exploded"
    end
  end
end
