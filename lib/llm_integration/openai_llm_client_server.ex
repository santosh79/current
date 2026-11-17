defmodule Current.LLMClient.OpenAIServer do
  use GenServer
  alias Current.LLMClient.{HTTP, Messages}

  @base_url "https://api.openai.com/v1"

  def provider(), do: "openai"

  @impl true
  def init(:ok) do
    state = %{:messages => []}
    {:ok, state}
  end

  @impl true
  def handle_call({:complete, prompt, timeout_ms, model}, _from, %{:messages => messages} = state) do
    messages = messages ++ [%{role: :user, content: prompt}]

    prompt_ready_messages =
      :lists.map(
        fn x ->
          case x do
            %{role: :assistant, content: assistant_content} ->
              %{role: :assistant, content: assistant_content.text}

            _ ->
              x
          end
        end,
        messages
      )

    res =
      with {:ok, api_key} <- api_key(),
           {:ok, body} <- encode_request(prompt_ready_messages, model),
           {:ok, raw_response} <- request(api_key, body, timeout_ms),
           {:ok, response} <- decode_response(raw_response) do
        {:ok, response}
      end

    case res do
      {:ok, response} ->
        messages = messages ++ [%{role: :assistant, content: response}]
        {:reply, res, %{state | messages: messages}}

      {:error, _} ->
        {:reply, res, state}
    end
  end

  @impl true
  def handle_call({:list_models, timeout_ms}, _from, state) do
    res =
      with {:ok, api_key} <- api_key(),
           {:ok, body} <- request_models(api_key, timeout_ms),
           {:ok, model_ids} <- decode_models(body) do
        {:ok, model_ids}
      end

    {:reply, res, state}
  end

  defp request_models(api_key, timeout_ms) do
    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}
    ]

    with {:ok, endpoint} <- HTTP.endpoint(__MODULE__, @base_url, "/models") do
      HTTP.request(:get, {endpoint, headers}, timeout_ms)
    end
  end

  defp decode_models(raw_body) do
    with {:ok, %{"data" => models}} when is_list(models) <- JSON.decode(raw_body) do
      model_ids = for %{"id" => id} <- models, is_binary(id), do: id
      {:ok, model_ids}
    else
      {:ok, _unexpected} -> {:error, :invalid_models_response}
      {:error, reason} -> {:error, {:decode_failed, reason}}
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

    base_body = %{
      "model" => model,
      "input" => Messages.encode(input)
    }

    body =
      cond do
        instructions ->
          base_body |> Map.put("instructions", instructions)

        true ->
          base_body
      end

    res = body |> JSON.encode!() |> IO.iodata_to_binary()
    {:ok, res}
  rescue
    error ->
      {:error, {:request_encode_failed, Exception.message(error)}}
  end

  @doc false
  def decode_response(body) do
    with {:ok, response} <- JSON.decode(body),
         {:ok, output} <- fetch_output(response),
         text <- output_text(output) do
      case String.length(text) do
        0 ->
          {:error, :no_output_text}

        _ ->
          {:ok, %{text: text, usage: normalize_usage(response["usage"])}}
      end
    end
  end

  defp fetch_output(%{"output" => output}) when is_list(output) do
    {:ok, output}
  end

  defp fetch_output(_response) do
    {:error, :missing_output}
  end

  #   Matching text blocks are concatenated across messages. Non-message
  #   entries, non-list content, and non-binary text values are ignored::
  #   
  #   Examples
  #   Multiple text blocks across messages are concatenated:
  #
  #     output_text([
  #       %{
  #         "type" => "message",
  #         "content" => [
  #           %{"type" => "output_text", "text" => "Hello"},
  #           %{"type" => "output_text", "text" => ", world!"}
  #         ]
  #       },
  #       %{
  #         "type" => "non-message",
  #         "content" => [
  #           %{"type" => "output_text", "text" => "Not Included"},
  #         ]
  #       },
  #       %{
  #         "type" => "message",
  #         "content" => "non list contents are not included"
  #       },
  #       %{
  #         "type" => "message",
  #         "content" => [
  #           %{"type" => "output_text", "text" => 123},
  #           %{"type" => "output_text", "text" => "\nHow are you?"}
  #         ]
  #       }
  #     ])
  #     # => "Hello, world!\nHow are you?"
  #
  defp output_text(output) do
    contents =
      :lists.filtermap(
        fn op ->
          case op do
            %{"type" => "message", "content" => content} when is_list(content) ->
              {true, content}

            _ ->
              false
          end
        end,
        output
      )
      |> :lists.flatten()

    texts =
      :lists.filtermap(
        fn x ->
          case x do
            %{"type" => "output_text", "text" => text} when is_binary(text) ->
              {true, text}

            _ ->
              false
          end
        end,
        contents
      )

    Enum.join(texts)
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

  defp api_key do
    case System.get_env("OPENAI_API_KEY") do
      key when key in [nil, ""] -> {:error, :missing_openai_api_key}
      key -> {:ok, key}
    end
  end
end
