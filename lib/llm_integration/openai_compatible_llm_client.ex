defmodule Current.LLMClient.OpenAICompatible do
  @moduledoc """
  An opt-in OpenAI Chat Completions provider for self-hosted models.

  It talks to one endpoint (Ollama, vLLM, llama.cpp, LM Studio, LiteLLM, ...)
  through `GET /models` and `POST /chat/completions`, and its models are named
  `local:<model-id>`. Model ids are not rewritten, including ids containing
  colons (for example, Ollama tags).

  The base URL, optional API key and output-token limit are read from
  `CURRENT_LOCAL_LLM_*` environment variables on every call. An unset or empty
  `CURRENT_LOCAL_LLM_BASE_URL` turns the provider off.
  """
  @behaviour Current.LLMClient

  alias Current.LLMClient.{HTTP, Messages}

  @env_prefix "CURRENT_LOCAL_LLM_"
  @max_tokens 16_000

  @impl true
  def provider, do: "local"

  @impl true
  def list_models(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, base} <- base_url(),
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, base, "/models"),
         {:ok, body} <- HTTP.request(:get, {endpoint, headers()}, timeout_ms) do
      decode_models(body)
    end
  end

  @impl true
  def complete(messages, timeout_ms, model)
      when is_list(messages) and is_integer(timeout_ms) and timeout_ms > 0 and is_binary(model) do
    with {:ok, base} <- base_url(),
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, base, "/chat/completions"),
         {:ok, max_tokens} <- positive_integer("MAX_TOKENS", @max_tokens),
         {:ok, body} <- encode_body(messages, model, max_tokens),
         request = {endpoint, headers(), ~c"application/json", body},
         {:ok, response} <- HTTP.request(:post, request, timeout_ms) do
      decode_response(response, max_tokens)
    end
  end

  ## --- Settings --------------------------------------------------------------

  # An empty variable counts as unset: compose files and shells routinely
  # pass `NAME=` for a value nobody chose.
  defp env(suffix) do
    case System.get_env(@env_prefix <> suffix) do
      "" -> nil
      value -> value
    end
  end

  defp base_url do
    case env("BASE_URL") do
      nil -> {:error, :missing_local_llm_base_url}
      base -> {:ok, base}
    end
  end

  defp headers do
    case env("API_KEY") do
      nil -> []
      key -> [{~c"authorization", String.to_charlist("Bearer " <> key)}]
    end
  end

  defp positive_integer(suffix, default) do
    case env(suffix) do
      nil ->
        {:ok, default}

      value ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, {:invalid_local_llm_setting, suffix}}
        end
    end
  end

  ## --- Completion ------------------------------------------------------------

  defp encode_body(messages, model, max_tokens) do
    {:ok,
     JSON.encode!(%{
       "model" => model,
       "messages" => Messages.encode(messages),
       "max_tokens" => max_tokens,
       "stream" => false
     })}
  rescue
    error -> {:error, {:request_encode_failed, Exception.message(error)}}
  end

  ## --- Decoding --------------------------------------------------------------

  @doc false
  def decode_response(body, max_tokens \\ @max_tokens) do
    with {:ok, response} <- decode_json(body) do
      case response do
        # Partial JSON is never handed to the proposal decoder.
        %{"choices" => [%{"finish_reason" => "length"} | _]} ->
          count = get_in(response, ["usage", "completion_tokens"])
          count = if is_integer(count) and count >= 0, do: count, else: max_tokens
          {:error, {:truncated, :length, count}}

        %{"choices" => [%{"message" => %{"content" => text}} | _]} when is_binary(text) ->
          case strip_thinking(text) do
            "" -> {:error, :no_output_text}
            text -> {:ok, %{text: text, usage: normalize_usage(response["usage"])}}
          end

        _ ->
          {:error, :no_output_text}
      end
    end
  end

  defp decode_models(body) do
    with {:ok, response} <- decode_json(body) do
      case response do
        %{"data" => models} when is_list(models) ->
          {:ok,
           models
           |> Enum.flat_map(fn
             %{"id" => id} when is_binary(id) and id != "" -> [id]
             _ -> []
           end)
           |> Enum.uniq()}

        _ ->
          {:error, :invalid_models_response}
      end
    end
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  # Reasoning models put their chain of thought in leading <think> blocks.
  # Only leading blocks are removed; one that never closes leaves nothing to
  # decode, and a literal "<think>" inside the answer is the answer's own.
  defp strip_thinking(text), do: text |> String.trim() |> drop_think_blocks() |> String.trim()

  defp drop_think_blocks("<think>" <> rest) do
    case String.split(rest, "</think>", parts: 2) do
      [_thinking, answer] -> answer |> String.trim_leading() |> drop_think_blocks()
      [_unterminated] -> ""
    end
  end

  defp drop_think_blocks(text), do: text

  defp normalize_usage(%{"prompt_tokens" => input, "completion_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    case Map.get(usage, "total_tokens", input + output) do
      total when is_integer(total) and total >= 0 ->
        %{input_tokens: input, output_tokens: output, total_tokens: total}

      _ ->
        nil
    end
  end

  defp normalize_usage(_usage), do: nil
end
