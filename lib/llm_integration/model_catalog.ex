defmodule Current.ModelCatalog do
  @moduledoc """
  Lists models from the configured LLM providers once at application startup
  and stores provider-qualified names in ETS.

  Entries have this form:

      "openai:gpt-5.6"
      "anthropic:claude-opus-5-5"
  """
  use GenServer

  @timeout_ms 10_000

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    tid = :ets.new(:catalog, [:set, :protected, read_concurrency: true])
    send(self(), :refresh)
    {:ok, %{tid: tid}}
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

  def llm_clients do
    Application.get_env(:current, :model_catalog_clients, [
      Current.LLMClient.OpenAI,
      Current.LLMClient.Anthropic
    ])
  end

  def all(pid) do
    GenServer.call(pid, :all)
  end

  def available?(pid, model_name) when is_binary(model_name) do
    GenServer.call(pid, {:available, model_name})
  end

  @impl true
  def handle_call({:available, model_name}, _from, %{tid: tid} = state) do
    result = :ets.member(tid, model_name)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:all, _from, %{tid: tid} = state) do
    result =
      tid
      |> :ets.tab2list()
      |> Enum.map(fn {model_name} -> model_name end)
      |> Enum.sort()

    {:reply, result, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    :ok = refresh_table(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp refresh_table(%{tid: tid} = _state) do
    models = build_mapping()

    case length(models) do
      0 ->
        :ok

      _ ->
        true = :ets.delete_all_objects(tid)
        true = :ets.insert(tid, Enum.map(models, &{&1}))
    end

    :ok
  end

  defp build_mapping() do
    llm_clients()
    |> Enum.flat_map(&models_for_client/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp models_for_client(client) do
    {:ok, pid} = client.start_link([])
    provider = client.provider()
    {:ok, models} = client.list_models(pid, @timeout_ms)

    Enum.map(models, fn model ->
      "#{provider}:#{model}"
    end)
  end
end
