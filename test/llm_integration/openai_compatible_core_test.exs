defmodule Current.LLMIntegration.OpenAICompatibleCoreTest do
  use ExUnit.Case, async: false

  alias Current.LLMClient.{HTTP, OpenAI, OpenAICompatible}

  test "local HTTP is allowed without weakening hosted-provider policy" do
    assert {:ok, ~c"http://host.docker.internal:11434/v1/models"} =
             HTTP.endpoint(
               OpenAICompatible,
               "http://host.docker.internal:11434/v1",
               "/models"
             )

    assert {:error, :invalid_provider_base_url} =
             HTTP.endpoint(OpenAI, "http://127.0.0.1/v1", "/models")
  end

  test "decoding rejects truncation before partial JSON" do
    raw =
      JSON.encode!(%{
        "choices" => [%{"finish_reason" => "length", "message" => %{"content" => "{"}}],
        "usage" => %{"completion_tokens" => 42}
      })

    assert {:error, {:truncated, :length, 42}} = OpenAICompatible.decode_response(raw)
  end

  test "decoding strips only leading think blocks" do
    body = fn text ->
      JSON.encode!(%{
        "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => text}}]
      })
    end

    assert {:ok, %{text: "{\"intents\":[]}"}} =
             OpenAICompatible.decode_response(
               body.("<think>private</think>\n{\"intents\":[]}")
             )

    literal = ~s({"text":"<think>keep this</think>"})
    assert {:ok, %{text: ^literal}} = OpenAICompatible.decode_response(body.(literal))
    assert {:error, :no_output_text} = OpenAICompatible.decode_response(body.("<think>open"))
  end

  test "model ids are kept verbatim and invalid replies are explicit" do
    assert {:error, :no_output_text} = OpenAICompatible.decode_response("{}")
    assert {:error, {:decode_failed, _}} = OpenAICompatible.decode_response("not json")
  end
end
