defmodule Current.LLMClient.OpenAI do
  @behaviour Current.LLMClient

  alias Current.LLMClient.{HTTP, Messages}

  @base_url "https://api.openai.com/v1"

  @impl true
  def provider(), do: "openai"

  @impl true
  def list_models(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, api_key} <- api_key(),
         {:ok, body} <- request_models(api_key, timeout_ms) do
      decode_models(body)
    end
  end

  @impl true
  def complete(messages, timeout_ms, model)
      when is_list(messages) and is_integer(timeout_ms) and timeout_ms > 0 and is_binary(model) do
    with {:ok, api_key} <- api_key(),
         {:ok, body} <- encode_request(messages, model),
         {:ok, response} <- request(api_key, body, timeout_ms) do
      decode_response(response)
    end
  end

  # Read per call, like the configured base URL.
  defp api_key do
    case System.get_env("OPENAI_API_KEY") do
      key when key in [nil, ""] -> {:error, :missing_openai_api_key}
      key -> {:ok, key}
    end
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

    with {:ok, endpoint} <- HTTP.endpoint(__MODULE__, @base_url, "/models") do
      HTTP.request(:get, {endpoint, headers}, timeout_ms)
    end
  end

  defp request(api_key, body, timeout_ms) do
    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}
    ]

    with {:ok, endpoint} <- HTTP.endpoint(__MODULE__, @base_url, "/responses") do
      HTTP.request(:post, {endpoint, headers, ~c"application/json", body}, timeout_ms)
    end
  end

  defp encode_request(messages, model) do
    {instructions, input} = Messages.split_system(messages)

    body =
      %{
        "model" => model,
        "input" => Messages.encode(input)
      }
      |> then(&if instructions, do: Map.put(&1, "instructions", instructions), else: &1)

    {:ok, JSON.encode!(body)}
  rescue
    error ->
      {:error, {:request_encode_failed, Exception.message(error)}}
  end

  @doc false
  def decode_response(body) do
    with {:ok, response} <- JSON.decode(body),
         {:ok, output} <- fetch_output(response),
         text when text != "" <- output_text(output) do
      {:ok, %{text: text, usage: normalize_usage(response["usage"])}}
    else
      {:error, reason} ->
        {:error, reason}

      "" ->
        {:error, :no_output_text}
    end
  end

  defp normalize_usage(%{
         "input_tokens" => input,
         "output_tokens" => output,
         "total_tokens" => total
       })
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
              is_integer(total) and total >= 0 do
    %{input_tokens: input, output_tokens: output, total_tokens: total}
  end

  defp normalize_usage(_usage), do: nil

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
