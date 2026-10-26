defmodule Current.LLMClient.Anthropic do
  @behaviour Current.LLMClient

  alias Current.LLMClient.{HTTP, Messages}

  @base_url "https://api.anthropic.com/v1"

  @api_version "2023-06-01"

  # Required by the Messages API. Proposals carry full diffs inline.
  @max_tokens 16_000

  @impl true
  def provider(), do: "anthropic"

  @impl true
  def list_models(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, api_key} <- api_key(),
         {:ok, response} <- request_models(api_key, timeout_ms) do
      extract_model_ids(response)
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
    case System.get_env("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] -> {:error, :missing_anthropic_api_key}
      key -> {:ok, key}
    end
  end

  defp request_models(api_key, timeout_ms) do
    headers = [
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", String.to_charlist(@api_version)}
    ]

    with {:ok, endpoint} <- HTTP.endpoint(__MODULE__, @base_url, "/models") do
      HTTP.request(:get, {endpoint, headers}, timeout_ms)
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

    with {:ok, endpoint} <- HTTP.endpoint(__MODULE__, @base_url, "/messages") do
      HTTP.request(:post, {endpoint, headers, ~c"application/json", body}, timeout_ms)
    end
  end

  defp encode_request(messages, model) do
    {system, chat} = Messages.split_system(messages)

    body =
      %{
        "model" => model,
        "max_tokens" => @max_tokens,
        "cache_control" => %{"type" => "ephemeral"},
        "messages" => Messages.encode(chat)
      }
      |> then(&if system, do: Map.put(&1, "system", system), else: &1)

    {:ok, JSON.encode!(body)}
  rescue
    error ->
      {:error, {:request_encode_failed, Exception.message(error)}}
  end

  @doc false
  def decode_response(body) do
    with {:ok, response} <- JSON.decode(body),
         {:ok, content} <- fetch_content(response),
         text when text != "" <- content_text(content) do
      {:ok, %{text: text, usage: normalize_usage(response["usage"])}}
    else
      {:error, reason} ->
        {:error, reason}

      "" ->
        {:error, :no_output_text}
    end
  end

  defp normalize_usage(%{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    with {:ok, cache_creation} <- optional_count(usage, "cache_creation_input_tokens"),
         {:ok, cache_read} <- optional_count(usage, "cache_read_input_tokens") do
      aggregate_input = input + cache_creation + cache_read

      %{
        input_tokens: aggregate_input,
        output_tokens: output,
        total_tokens: aggregate_input + output
      }
      |> put_optional_count(usage, "cache_creation_input_tokens", cache_creation)
      |> put_optional_count(usage, "cache_read_input_tokens", cache_read)
    else
      :error -> nil
    end
  end

  defp normalize_usage(_usage), do: nil

  defp optional_count(usage, key) do
    case Map.fetch(usage, key) do
      :error -> {:ok, 0}
      {:ok, count} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, _invalid} -> :error
    end
  end

  defp put_optional_count(normalized, source, source_key, count) do
    if Map.has_key?(source, source_key) do
      normalized_key = String.to_existing_atom(source_key)
      Map.put(normalized, normalized_key, count)
    else
      normalized
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
