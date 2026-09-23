defmodule Current.LLMClient.OpenAI do
  @behaviour Current.LLMClient

  @endpoint "https://api.openai.com/v1/responses"
  @default_model "gpt-5.6"

  @connect_timeout_ms 10_000

  @impl true
  def complete(prompt, timeout_ms)
      when is_binary(prompt) and is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, api_key} <- api_key(),
         {:ok, body} <- encode_request(prompt),
         {:ok, response} <- request(api_key, body, timeout_ms),
         {:ok, text} <- extract_text(response) do
      {:ok, text}
    end
  end

  defp encode_request(prompt) do
    body = %{
      "model" => model(),
      "input" => prompt
    }

    {:ok, JSON.encode!(body)}
  rescue
    error ->
      {:error, {:request_encode_failed, Exception.message(error)}}
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

  defp api_key do
    case System.get_env("OPENAI_API_KEY") do
      nil -> {:error, :missing_openai_api_key}
      "" -> {:error, :missing_openai_api_key}
      key -> {:ok, key}
    end
  end

  defp model do
    Application.get_env(
      :current,
      :openai_model,
      @default_model
    )
  end
end
