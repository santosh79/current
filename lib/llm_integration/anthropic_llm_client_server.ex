defmodule Current.LLMClient.AnthropicServer do
  use GenServer

  alias Current.LLMClient.{HTTP}

  @base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @impl true
  def init(:ok) do
    state = %{}
    {:ok, state}
  end

  @impl true
  def handle_call({:list_models, timeout_ms}, _from, state) do
    res =
      with {:ok, response} <- request_models(timeout_ms) do
        extract_model_ids(response)
      end

    {:reply, res, state}
  end

  defp request_models(timeout_ms) do
    with {:ok, api_key} <- api_key(),
         headers <- [
           {~c"x-api-key", String.to_charlist(api_key)},
           {~c"anthropic-version", String.to_charlist(@api_version)}
         ],
         {:ok, endpoint} <- HTTP.endpoint(__MODULE__, @base_url, "/models"),
         {:ok, res} <- HTTP.request(:get, {endpoint, headers}, timeout_ms) do
      {:ok, res}
    end
  end

  defp extract_model_ids(body) do
    with {:ok, %{"data" => models}} when is_list(models) <- JSON.decode(body) do
      model_ids =
        :lists.filtermap(
          fn x ->
            case x do
              %{"id" => id} when is_binary(id) and id != "" ->
                {true, id}

              _ ->
                false
            end
          end,
          models
        )
        |> :lists.sort()

      {:ok, model_ids}
    else
      {:ok, _response} ->
        {:error, :missing_models}

      {:error, reason} ->
        {:error, {:decode_failed, reason}}
    end
  end

  defp api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] -> {:error, :missing_anthropic_api_key}
      key -> {:ok, key}
    end
  end
end
