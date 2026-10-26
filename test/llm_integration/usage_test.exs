defmodule Current.LLMIntegration.UsageTest do
  use ExUnit.Case, async: true

  alias Current.LLMClient.{Anthropic, OpenAI}

  test "OpenAI decodes text and normalized usage" do
    body =
      JSON.encode!(%{
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "hello"}]
          }
        ],
        "usage" => %{"input_tokens" => 120, "output_tokens" => 30, "total_tokens" => 150}
      })

    assert {:ok,
            %{
              text: "hello",
              usage: %{input_tokens: 120, output_tokens: 30, total_tokens: 150}
            }} = OpenAI.decode_response(body)
  end

  test "Anthropic preserves cache counts and includes them in aggregate input usage" do
    body =
      JSON.encode!(%{
        "content" => [%{"type" => "text", "text" => "hello"}],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 20,
          "cache_creation_input_tokens" => 50,
          "cache_read_input_tokens" => 100,
          "output_tokens" => 30
        }
      })

    assert {:ok,
            %{
              text: "hello",
              usage: %{
                input_tokens: 170,
                output_tokens: 30,
                total_tokens: 200,
                cache_creation_input_tokens: 50,
                cache_read_input_tokens: 100
              }
            }} = Anthropic.decode_response(body)
  end

  test "missing or malformed usage remains nil without rejecting valid text" do
    openai =
      JSON.encode!(%{
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "hello"}]
          }
        ]
      })

    anthropic =
      JSON.encode!(%{
        "content" => [%{"type" => "text", "text" => "hello"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => "unknown", "output_tokens" => 4}
      })

    assert OpenAI.decode_response(openai) == {:ok, %{text: "hello", usage: nil}}
    assert Anthropic.decode_response(anthropic) == {:ok, %{text: "hello", usage: nil}}
  end
end
