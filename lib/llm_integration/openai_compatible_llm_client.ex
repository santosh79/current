defmodule Current.LLMClient.OpenAICompatible do
  @moduledoc """
  An opt-in OpenAI Chat Completions provider for self-hosted models.

  It talks to one endpoint (Ollama, vLLM, llama.cpp, LM Studio, LiteLLM, ...)
  through `GET /models` and `POST /chat/completions`, and its models are named
  `local:<model-id>`. Model ids are not rewritten, including ids containing
  colons (for example, Ollama tags).

  Settings are read from `CURRENT_LOCAL_LLM_*` environment variables on every
  call, so a server and its settings can change without rebuilding Current.
  An unset or empty `CURRENT_LOCAL_LLM_BASE_URL` turns the provider off. See
  docs/self_hosted_models.md for the full list.
  """
  @behaviour Current.LLMClient

  alias Current.LLMClient.{HTTP, Messages}

  @env_prefix "CURRENT_LOCAL_LLM_"
  @max_tokens 16_000

  # Fields that belong to the protocol Current speaks, not to the operator.
  # Extra request fields can never set or replace them.
  @protocol_fields ~w(response_format stream model messages max_tokens max_completion_tokens)

  @impl true
  def provider, do: "local"

  @impl true
  def list_models(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, base} <- base_url(),
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, base, "/models"),
         {:ok, body} <- HTTP.request(:get, {endpoint, headers()}, timeout_ms, __MODULE__) do
      decode_models(body)
    end
  end

  @impl true
  def complete(messages, timeout_ms, model)
      when is_list(messages) and is_integer(timeout_ms) and timeout_ms > 0 and is_binary(model) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, base} <- base_url(),
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, base, "/chat/completions"),
         {:ok, options} <- settings() do
      attempt(messages, model, endpoint, options, modes(options.format), deadline)
    end
  end

  @doc false
  # Validate local timeout overrides before a task starts.
  def timeouts(call_default, task_default) do
    with {:ok, call_ms} <- positive_integer("PROPOSAL_TIMEOUT_MS", call_default),
         {:ok, task_ms} <- positive_integer("TASK_TIMEOUT_MS", task_default) do
      {:ok, {call_ms, task_ms}}
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

  defp settings do
    with {:ok, max_tokens} <- positive_integer("MAX_TOKENS", @max_tokens),
         {:ok, _} <- positive_integer("PROPOSAL_TIMEOUT_MS", 240_000),
         {:ok, _} <- positive_integer("TASK_TIMEOUT_MS", 600_000),
         {:ok, format} <-
           choice("RESPONSE_FORMAT", "auto", ["auto", "json_schema", "json", "none"]),
         {:ok, strict} <- choice("JSON_SCHEMA_STRICT", "false", ["true", "false"]),
         {:ok, extra} <- extra_fields() do
      {:ok, %{max_tokens: max_tokens, format: format, strict: strict == "true", extra: extra}}
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

  defp choice(suffix, default, allowed) do
    value = env(suffix) || default
    if value in allowed, do: {:ok, value}, else: {:error, {:invalid_local_llm_setting, suffix}}
  end

  defp extra_fields do
    case JSON.decode(env("EXTRA_FIELDS") || "{}") do
      {:ok, extra} when is_map(extra) -> {:ok, extra}
      _ -> {:error, {:invalid_local_llm_setting, "EXTRA_FIELDS"}}
    end
  end

  ## --- Completion ------------------------------------------------------------

  # Try simpler response formats only when a server rejects the current one.
  defp modes("auto"), do: ["json_schema", "json", "none"]
  defp modes(format), do: [format]

  # Every attempt may use all the time that is left: a rejected response
  # format comes back quickly, so no time is held in reserve for fallbacks,
  # and the caller's deadline is never extended by a retry.
  defp attempt(messages, model, endpoint, options, [mode | rest], deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      with {:ok, body} <- encode_body(messages, model, options, mode) do
        request = {endpoint, headers(), ~c"application/json", body}

        case HTTP.request(:post, request, remaining, __MODULE__) do
          {:ok, response} ->
            decode_response(response, options.max_tokens)

          {:error, _} = error ->
            if rest != [] and format_error?(error) do
              attempt(messages, model, endpoint, options, rest, deadline)
            else
              error
            end
        end
      end
    end
  end

  defp encode_body(messages, model, options, mode) do
    {:ok, JSON.encode!(request_body(messages, model, options, mode))}
  rescue
    error -> {:error, {:request_encode_failed, Exception.message(error)}}
  end

  defp request_body(messages, model, options, mode) do
    # Protocol-owned fields cannot be overridden by extra fields. In particular,
    # `none` must really omit response_format, even if supplied in extra fields.
    body =
      options.extra
      |> Map.drop(@protocol_fields)
      |> Map.merge(%{
        "model" => model,
        "messages" => Messages.encode(messages),
        "max_tokens" => options.max_tokens,
        "stream" => false
      })

    case mode do
      "none" ->
        body

      "json" ->
        Map.put(body, "response_format", %{"type" => "json_object"})

      "json_schema" ->
        Map.put(body, "response_format", %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "current_reply",
            "strict" => options.strict,
            "schema" => JSON.decode!(Current.ProposalWireSchema.raw())
          }
        })
    end
  end

  # Only a rejection that is about the response format falls back to a
  # simpler one. Context-window overflows also come back as 400s, often
  # mentioning the same field; retrying those could never help and would hide
  # the real error.
  defp format_error?({:error, {:http_error, status, body}})
       when status in [400, 422] and is_binary(body) do
    body = String.downcase(body)

    String.contains?(body, ["response_format", "json_schema"]) and
      not String.contains?(body, [
        "context_length",
        "context length",
        "context window",
        "too many tokens",
        "maximum context"
      ])
  end

  defp format_error?(_), do: false

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
