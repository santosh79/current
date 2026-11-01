defmodule Current.LLMIntegration.OpenAICompatibleTest do
  use ExUnit.Case, async: false

  alias Current.LLMClient.OpenAICompatible

  setup do
    previous = Application.fetch_env(:current, OpenAICompatible)
    Application.delete_env(:current, OpenAICompatible)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:current, OpenAICompatible, config)
        :error -> Application.delete_env(:current, OpenAICompatible)
      end
    end)

    :ok
  end

  test "identifies itself as the openai_compatible provider" do
    assert OpenAICompatible.provider() == "openai_compatible"
  end

  test "encodes a non-streaming Chat Completions request including system messages" do
    messages = [
      %{role: :system, content: "Follow the schema."},
      %{role: :user, content: "Make a proposal."}
    ]

    assert {:ok, body} = OpenAICompatible.encode_request(messages, "qwen:latest")
    assert {:ok, decoded} = JSON.decode(body)

    assert decoded == %{
             "model" => "qwen:latest",
             "messages" => [
               %{"role" => "system", "content" => "Follow the schema."},
               %{"role" => "user", "content" => "Make a proposal."}
             ],
             "stream" => false,
             "max_tokens" => 16_000
           }
  end

  test "uses a configured output-token allowance" do
    Application.put_env(:current, OpenAICompatible, max_tokens: 8_192)

    assert {:ok, body} =
             OpenAICompatible.encode_request([%{role: :user, content: "hello"}], "model")

    assert {:ok, %{"max_tokens" => 8_192}} = JSON.decode(body)
  end

  test "decodes discovered model IDs and preserves IDs containing colons" do
    body =
      JSON.encode!(%{
        "data" => [
          %{"id" => "qwen3-coder:latest", "object" => "model"},
          %{"id" => "another-model"},
          %{"unexpected" => true}
        ]
      })

    assert OpenAICompatible.decode_models(body) ==
             {:ok, ["another-model", "qwen3-coder:latest"]}
  end

  test "rejects malformed model discovery responses" do
    assert OpenAICompatible.decode_models(~s({"models": []})) ==
             {:error, :invalid_models_response}

    assert {:error, {:decode_failed, _reason}} = OpenAICompatible.decode_models("not json")
  end

  test "normalizes completion text and token usage" do
    body =
      JSON.encode!(%{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => ~s({"intents":[]}),
              "reasoning_content" => "internal reasoning"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 120,
          "completion_tokens" => 30,
          "total_tokens" => 150
        }
      })

    assert OpenAICompatible.decode_response(body) ==
             {:ok,
              %{
                text: ~s({"intents":[]}),
                usage: %{input_tokens: 120, output_tokens: 30, total_tokens: 150}
              }}
  end

  test "accepts valid output when usage is absent or malformed" do
    without_usage =
      JSON.encode!(%{
        "choices" => [
          %{"message" => %{"content" => "hello"}, "finish_reason" => "stop"}
        ]
      })

    malformed_usage =
      JSON.encode!(%{
        "choices" => [
          %{"message" => %{"content" => "hello"}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => "unknown"}
      })

    assert OpenAICompatible.decode_response(without_usage) ==
             {:ok, %{text: "hello", usage: nil}}

    assert OpenAICompatible.decode_response(malformed_usage) ==
             {:ok, %{text: "hello", usage: nil}}
  end

  test "returns explicit errors for malformed, missing, empty, and truncated output" do
    assert {:error, {:decode_failed, _reason}} = OpenAICompatible.decode_response("not json")

    assert OpenAICompatible.decode_response(~s({"choices": []})) ==
             {:error, :missing_choices}

    missing = JSON.encode!(%{"choices" => [%{"finish_reason" => "stop"}]})
    assert OpenAICompatible.decode_response(missing) == {:error, :missing_message}

    empty =
      JSON.encode!(%{
        "choices" => [%{"message" => %{"content" => ""}, "finish_reason" => "stop"}]
      })

    assert OpenAICompatible.decode_response(empty) == {:error, :no_output_text}

    reasoning_only =
      JSON.encode!(%{
        "choices" => [
          %{
            "message" => %{"content" => nil, "reasoning_content" => "not the final answer"},
            "finish_reason" => "stop"
          }
        ]
      })

    assert OpenAICompatible.decode_response(reasoning_only) == {:error, :no_output_text}

    truncated =
      JSON.encode!(%{
        "choices" => [
          %{"message" => %{"content" => "partial"}, "finish_reason" => "length"}
        ]
      })

    assert OpenAICompatible.decode_response(truncated) ==
             {:error, {:truncated, :length, 16_000}}
  end

  test "preserves structured provider errors" do
    body = JSON.encode!(%{"error" => %{"message" => "model is not loaded"}})

    assert OpenAICompatible.decode_response(body) ==
             {:error, {:provider_error, %{"message" => "model is not loaded"}}}
  end

  test "requires operator configuration before model discovery" do
    assert OpenAICompatible.list_models(1_000) == {:error, :invalid_provider_base_url}
  end
end
