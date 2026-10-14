defmodule Current.LLMClient.OpenAI do
  use GenServer

  @connect_timeout_ms 10_000
  @models_endpoint "https://api.openai.com/v1/models"
  @endpoint "https://api.openai.com/v1/responses"

  def provider() do
    "openai"
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, :missing_openai_api_key}

      "" ->
        {:error, :missing_openai_api_key}

      key ->
        {:ok, %{api_key: key}}
    end
  end

  def list_models(pid, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(pid, {:list_models, timeout_ms}, timeout_ms)
  end

  def complete(pid, prompt, timeout_ms, model)
      when is_binary(prompt) and is_integer(timeout_ms) and timeout_ms > 0 and is_binary(model) do
    GenServer.call(pid, {:complete, prompt, model, timeout_ms}, timeout_ms)
  end

  @impl true
  def handle_call({:complete, prompt, model, timeout_ms}, _from, %{api_key: api_key} = state) do
    res =
      case encode_request(prompt, model) do
        {:error, reason} ->
          {:error, reason}

        {:ok, body} ->
          case request(api_key, body, timeout_ms) do
            {:error, reason} ->
              {:error, reason}

            {:ok, response} ->
              case extract_text(response) do
                {:error, reason} -> {:error, reason}
                {:ok, text} -> {:ok, text}
              end
          end
      end

    {:reply, res, state}
  end

  @impl true
  def handle_call({:list_models, timeout_ms}, _from, %{api_key: api_key} = state) do
    res =
      case request_models(api_key, timeout_ms) do
        {:error, reason} ->
          {:error, reason}

        {:ok, body} ->
          case decode_models(body) do
            {:error, reason} -> {:error, reason}
            {:ok, model_ids} -> {:ok, model_ids}
          end
      end

    {:reply, res, state}
  end

  defp decode_models(body) do
    with {:ok, %{"data" => models}} when is_list(models) <- JSON.decode(body) do
      model_ids =
        for %{"id" => id} <- models, is_binary(id), do: id

      {:ok, model_ids}
    else
      {:ok, _unexpected} -> {:error, :invalid_models_response}
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  defp request_models(api_key, timeout_ms) do
    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}
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
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp request(api_key, body, timeout_ms) do
    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}
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
      "input" => prompt
    }

    {:ok, JSON.encode!(body)}
  rescue
    error ->
      {:error, {:request_encode_failed, Exception.message(error)}}
  end

  defp extract_text(body) do
    with {:ok, response} <- JSON.decode(body),
         {:ok, output} <- fetch_output(response),
         text when text != "" <- output_text(output) do
      {:ok, text}
    else
      {:error, reason} ->
        {:error, reason}

      "" ->
        {:error, :no_output_text}
    end
  end

  defp fetch_output(%{"output" => output}) when is_list(output) do
    {:ok, output}
  end

  defp fetch_output(_response) do
    {:error, :missing_output}
  end

  defp output_text(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => content}
      when is_list(content) ->
        content

      _ ->
        []
    end)
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text}
      when is_binary(text) ->
        [text]

      _ ->
        []
    end)
    |> Enum.join()
  end
end
