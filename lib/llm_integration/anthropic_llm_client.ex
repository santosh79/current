defmodule Current.LLMClient.Anthropic do
  @behaviour Current.LLMClient

  @endpoint "https://api.anthropic.com/v1/messages"
  @models_endpoint "https://api.anthropic.com/v1/models"

  @api_version "2023-06-01"

  # Required by the Messages API. Proposals carry full diffs inline.
  @max_tokens 16_000
  @connect_timeout_ms 10_000

  @impl true
  def provider() do
    "anthropic"
  end

  # Completes on the given provider-native model.
  @impl Current.LLMClient
  def complete(prompt, timeout_ms, model)
      when is_binary(prompt) and is_integer(timeout_ms) and timeout_ms > 0 and is_binary(model) do
    with {:ok, api_key} <- api_key(),
         {:ok, body} <- encode_request(prompt, model),
         {:ok, response} <- request(api_key, body, timeout_ms),
         {:ok, text} <- extract_text(response) do
      {:ok, text}
    end
  end

  @impl Current.LLMClient
  def list_models(timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, api_key} <- api_key(),
         {:ok, response} <- request_models(api_key, timeout_ms),
         {:ok, model_ids} <- extract_model_ids(response) do
      {:ok, model_ids}
    end
  end

  defp request(api_key, body, timeout_ms) do
    headers = [
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", String.to_charlist(@api_version)}
    ]

    case :httpc.request(
           :post,
           {
             String.to_charlist(@endpoint),
             headers,
             ~c"application/json",
             body
           },
           [
             connect_timeout: min(@connect_timeout_ms, timeout_ms),
             timeout: timeout_ms
           ],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp extract_text(body) do
    with {:ok, response} <- JSON.decode(body),
         {:ok, content} <- fetch_content(response),
         text when text != "" <- content_text(content) do
      {:ok, text}
    else
      {:error, reason} ->
        {:error, reason}

      "" ->
        {:error, :no_output_text}
    end
  end

  # A response cut off at max_tokens is half a JSON object; report that
  # rather than letting it surface later as a decode error.
  defp fetch_content(%{"stop_reason" => "max_tokens"}) do
    {:error, {:truncated, :max_tokens, @max_tokens}}
  end

  defp fetch_content(%{"content" => content}) when is_list(content) do
    {:ok, content}
  end

  defp fetch_content(_response) do
    {:error, :missing_content}
  end

  defp content_text(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join()
  end

  defp api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :missing_anthropic_api_key}
      "" -> {:error, :missing_anthropic_api_key}
      key -> {:ok, key}
    end
  end

  defp request_models(api_key, timeout_ms) do
    headers = [
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", String.to_charlist(@api_version)}
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(@models_endpoint), headers},
           [
             connect_timeout: min(@connect_timeout_ms, timeout_ms),
             timeout: timeout_ms
           ],
           body_format: :binary
         ) do
      {:ok, {{_http_version, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_http_version, status, _reason}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp extract_model_ids(body) do
    with {:ok, %{"data" => models}} when is_list(models) <- JSON.decode(body) do
      model_ids =
        models
        |> Enum.flat_map(fn
          %{"id" => id} when is_binary(id) and id != "" -> [id]
          _ -> []
        end)
        |> Enum.sort()

      {:ok, model_ids}
    else
      {:ok, _response} ->
        {:error, :missing_models}

      {:error, reason} ->
        {:error, {:decode_failed, reason}}
    end
  end

  defp encode_request(prompt, model) do
    body = %{
      "model" => model,
      "max_tokens" => @max_tokens,
      "cache_control" => %{"type" => "ephemeral"},
      "messages" => [%{"role" => "user", "content" => prompt}]
    }

    {:ok, JSON.encode!(body)}
  rescue
    error ->
      {:error, {:request_encode_failed, Exception.message(error)}}
  end
end
