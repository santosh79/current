defmodule Current.LLMClient.Anthropic do
  use GenServer

  @endpoint "https://api.anthropic.com/v1/messages"
  @models_endpoint "https://api.anthropic.com/v1/models"

  @api_version "2023-06-01"

  # Required by the Messages API. Proposals carry full diffs inline.
  @max_tokens 16_000
  @connect_timeout_ms 10_000

  def provider() do
    "anthropic"
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, :missing_anthropic_api_key}

      "" ->
        {:error, :missing_anthropic_api_key}

      key ->
        {:ok, %{api_key: key}}
    end
  end

  def list_models(pid, timeout_ms)
      when is_integer(timeout_ms) and
             timeout_ms > 0 do
    GenServer.call(pid, {:list_models, timeout_ms}, timeout_ms)
  end

  def complete(pid, prompt, timeout_ms, model)
      when is_binary(prompt) and is_integer(timeout_ms) and
             timeout_ms > 0 and is_binary(model) do
    GenServer.call(pid, {:complete, prompt, model, timeout_ms}, timeout_ms)
  end

  def handle_call({:complete, prompt, model, timeout_ms}, _from, %{api_key: api_key} = state) do
    response =
      with {:ok, body} <- encode_request(prompt, model),
           {:ok, response} <- request(api_key, body, timeout_ms),
           {:ok, text} <- extract_text(response) do
        {:ok, text}
      end

    {:reply, response, state}
  end

  @impl true
  def handle_call({:list_models, timeout_ms}, _from, %{api_key: api_key} = state) do
    response =
      with {:ok, response} <- request_models(api_key, timeout_ms),
           {:ok, model_ids} <- extract_model_ids(response) do
        {:ok, model_ids}
      end

    {:reply, response, state}
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
end
