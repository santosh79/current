defmodule Current.ModelCatalog do
  @moduledoc """
  ETS snapshot of models discovered from configured providers.

  Reads never contact a provider. Discovery runs once, under the catalog
  process, after startup. Restart the runtime to discover model changes.
  """
  use GenServer

  @timeout_ms 10_000

  def start_link([]), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    tid = :ets.new(:catalog, [:set, :protected, read_concurrency: true])
    send(self(), :discover)
    {:ok, tid}
  end

  def find_supervisor_pid do
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
      Current.LLMClient.Anthropic,
      Current.LLMClient.OpenAICompatible
    ])
  end

  @doc "The current model snapshot; never performs network I/O."
  def all(pid), do: GenServer.call(pid, :all)

  @doc "Checks the current snapshot; never performs network I/O."
  def available?(pid, name) when is_binary(name),
    do: GenServer.call(pid, {:available, name})

  @impl true
  def handle_call(:all, _from, tid), do: {:reply, models(tid), tid}

  def handle_call({:available, name}, _from, tid),
    do: {:reply, :ets.member(tid, name), tid}

  @impl true
  def handle_info(:discover, tid) do
    entries =
      for {_provider, {:ok, names}} <- discover(), name <- names, uniq: true, do: {name}

    :ets.insert(tid, entries)
    {:noreply, tid}
  end

  defp models(tid), do: tid |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  defp discover do
    clients = llm_clients()

    clients
    |> Task.async_stream(&models_for_client/1,
      max_concurrency: max(length(clients), 1),
      timeout: @timeout_ms + 1_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {provider, result}} -> [{provider, result}]
      _ -> []
    end)
  catch
    _, _ -> []
  end

  defp models_for_client(client) do
    provider = client.provider()

    case client.list_models(@timeout_ms) do
      {:ok, ids} when is_list(ids) ->
        names = for id <- ids, is_binary(id) and id != "", do: "#{provider}:#{id}"
        {provider, {:ok, names}}

      _ ->
        {provider, :error}
    end
  catch
    _, _ -> {provider, :error}
  end
end
