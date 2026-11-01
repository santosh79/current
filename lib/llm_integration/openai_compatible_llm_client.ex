defmodule Current.LLMClient.OpenAICompatible do
  @moduledoc """
  Client for inference servers that implement OpenAI-compatible Chat
  Completions and model-listing endpoints.

  Configure the server with application environment:

      config :current, Current.LLMClient.OpenAICompatible,
        base_url: "https://inference.example.com/v1",
        api_key_env: "CURRENT_INFERENCE_API_KEY",
        max_tokens: 16_000

  `api_key_env` is optional. When present, its value is read for every call.
  The shared HTTP transport continues to require HTTPS; explicitly permitted
  loopback HTTP support belongs to the later transport phase.
  """

  @behaviour Current.LLMClient

  alias Current.LLMClient.{HTTP, Messages}

  @default_max_tokens 16_000

  @impl true
  def provider(), do: "openai_compatible"

  @impl true
  def list_models(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, headers} <- headers(),
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, nil, "/models"),
         {:ok, body} <- HTTP.request(:get, {endpoint, headers}, timeout_ms) do
      decode_models(body)
    end
  end

  @impl true
  def complete(messages, timeout_ms, model)
      when is_list(messages) and is_integer(timeout_ms) and timeout_ms > 0 and is_binary(model) do
    with {:ok, headers} <- headers(),
         {:ok, body} <- encode_request(messages, model),
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, nil, "/chat/completions"),
         {:ok, response} <-
           HTTP.request(:post, {endpoint, headers, ~c"application/json", body}, timeout_ms) do
      decode_response(response)
    end
  end

  defp headers do
    config = Application.get_env(:current, __MODULE__, [])

    case Keyword.get(config, :api_key_env) do
      nil ->
        {:ok, []}

      env when is_binary(env) and env != "" ->
        case System.get_env(env) do
          key when key in [nil, ""] -> {:error, {:missing_api_key, env}}
          key -> {:ok, [{~c"authorization", ~c"Bearer " ++ String.to_charlist(key)}]}
        end

      _invalid ->
        {:error, :invalid_api_key_env}
    end
  end

  defp max_tokens do
    case :current |> Application.get_env(__MODULE__, []) |> Keyword.get(:max_tokens) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_tokens
    end
  end

  @doc false
  def encode_request(messages, model) do
    body = %{
      "model" => model,
      "messages" => Messages.encode(messages),
      "stream" => false,
      "max_tokens" => max_tokens()
    }

    {:ok, JSON.encode!(body)}
  rescue
    error -> {:error, {:request_encode_failed, Exception.message(error)}}
  end

  @doc false
  def decode_models(body) do
    with {:ok, response} <- decode_json(body),
         {:ok, models} <- fetch_models(response) do
      model_ids =
        for %{"id" => id} <- models, is_binary(id), id != "", do: id

      {:ok, Enum.sort(model_ids)}
    end
  end

  @doc false
  def decode_response(body) do
    with {:ok, response} <- decode_json(body),
         :ok <- reject_provider_error(response),
         {:ok, choice} <- fetch_choice(response),
         :ok <- reject_truncation(choice),
         {:ok, text} <- fetch_text(choice),
         true <- text != "" do
      {:ok, %{text: text, usage: normalize_usage(response["usage"])}}
    else
      false -> {:error, :no_output_text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  defp fetch_models(%{"data" => models}) when is_list(models), do: {:ok, models}
  defp fetch_models(_response), do: {:error, :invalid_models_response}

  defp reject_provider_error(%{"error" => error}), do: {:error, {:provider_error, error}}
  defp reject_provider_error(_response), do: :ok

  defp fetch_choice(%{"choices" => [choice | _]}) when is_map(choice), do: {:ok, choice}
  defp fetch_choice(_response), do: {:error, :missing_choices}

  defp reject_truncation(%{"finish_reason" => "length"}),
    do: {:error, {:truncated, :length, max_tokens()}}

  defp reject_truncation(_choice), do: :ok

  # Deliberately ignore reasoning_content. Current consumes only the final
  # answer and never records a provider's private reasoning as proposal text.
  defp fetch_text(%{"message" => %{"content" => content}}) when is_binary(content),
    do: {:ok, content}

  defp fetch_text(%{"message" => _message}), do: {:error, :no_output_text}
  defp fetch_text(_choice), do: {:error, :missing_message}

  defp normalize_usage(%{
         "prompt_tokens" => input,
         "completion_tokens" => output,
         "total_tokens" => total
       })
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
              is_integer(total) and total >= 0 do
    %{input_tokens: input, output_tokens: output, total_tokens: total}
  end

  defp normalize_usage(_usage), do: nil
end
