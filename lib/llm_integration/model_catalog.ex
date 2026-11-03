defmodule Current.ModelCatalog do
  @moduledoc """
  Lists models from the configured LLM providers once at application startup
  and keeps, in its state, a map from each provider-qualified model name to
  the client that serves it:

      %{
        "openai:gpt-5.6" => Current.LLMClient.OpenAI,
        "anthropic:claude-opus-5-5" => Current.LLMClient.Anthropic
      }
  """
  use GenServer

  @timeout_ms 10_000

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    send(self(), :refresh)
    {:ok, %{}}
  end

  def find_supervisor_pid() do
    pid =
      Supervisor.which_children(Current.RuntimeSupervisor)
      |> Enum.find_value(fn
        {Current.ModelCatalog, pid, :worker, _modules} when is_pid(pid) -> pid
        _ -> nil
      end)

    {:ok, pid}
  end

  def all(pid) do
    GenServer.call(pid, :all)
  end

  def available?(pid, model_name) when is_binary(model_name) do
    GenServer.call(pid, {:available, model_name})
  end

  @doc "The client module for a model name: `{:ok, client}` or `:error`."
  def resolve(pid, model_name) when is_binary(model_name) do
    GenServer.call(pid, {:resolve, model_name})
  end

  @impl true
  def handle_call(:all, _from, models) do
    {:reply, models |> Map.keys() |> Enum.sort(), models}
  end

  def handle_call({:available, model_name}, _from, models) do
    {:reply, Map.has_key?(models, model_name), models}
  end

  def handle_call({:resolve, model_name}, _from, models) do
    {:reply, Map.fetch(models, model_name), models}
  end

  @impl true
  def handle_info(:refresh, models) do
    case build_mapping() do
      empty when map_size(empty) == 0 -> {:noreply, models}
      refreshed -> {:noreply, refreshed}
    end
  end

  def handle_info(_message, models) do
    {:noreply, models}
  end

  defp llm_clients do
    Application.get_env(:current, :model_catalog_clients, [
      Current.LLMClient.OpenAI,
      Current.LLMClient.Anthropic
    ])
  end

  defp build_mapping() do
    llm_clients()
    |> Enum.flat_map(&models_for_client/1)
    |> Map.new()
  end

  # A provider that is unconfigured or unreachable contributes no models;
  # it must not take the catalog (and the runtime under it) down.
  defp models_for_client(client) do
    case client.list_models(@timeout_ms) do
      {:ok, models} -> Enum.map(models, &{"#{client.provider()}:#{&1}", client})
      {:error, _reason} -> []
    end
  catch
    _kind, _reason -> []
  end
end
