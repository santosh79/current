defmodule Current.ModelCatalog do
  @moduledoc """
  ETS snapshot of models discovered from configured providers.

  Reads never contact a provider. Discovery runs once at startup and only
  when explicitly requested with `refresh/1` (`current models --refresh`).
  Refresh performs network I/O in the caller, never in this GenServer.
  """
  use GenServer

  @timeout_ms 10_000

  def start_link([]), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    tid = :ets.new(:catalog, [:set, :protected, read_concurrency: true])
    catalog = self()
    # Unlinked: a failed startup discovery must not restart the catalog.
    spawn(fn -> refresh(catalog) end)
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

  @doc "Discover models now, then publish results to the catalog."
  def refresh(pid) do
    GenServer.call(pid, {:replace, discover()}, @timeout_ms + 2_000)
  end

  @impl true
  def handle_call(:all, _from, tid), do: {:reply, models(tid), tid}

  def handle_call({:available, name}, _from, tid),
    do: {:reply, :ets.member(tid, name), tid}

  def handle_call({:replace, results}, _from, tid) do
    Enum.each(results, fn {provider, result} ->
      case result do
        {:ok, names} ->
          prefix = provider <> ":"

          for {name} <- :ets.tab2list(tid), String.starts_with?(name, prefix) do
            :ets.delete(tid, name)
          end

          :ets.insert(tid, Enum.map(Enum.uniq(names), &{&1}))

        :error ->
          # A transient failure leaves that provider's last successful snapshot.
          :ok
      end
    end)

    {:reply, models(tid), tid}
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

    # Disabled is not the same as unreachable: clear a deliberately disabled
    # local provider, but retain models after a temporary network failure.
    result =
      if client == Current.LLMClient.OpenAICompatible and
           System.get_env("CURRENT_LOCAL_LLM_BASE_URL") in [nil, ""] do
        {:ok, []}
      else
        client.list_models(@timeout_ms)
      end

    case result do
      {:ok, ids} when is_list(ids) ->
        rr = ids |> Enum.filter(fn(id) ->
          is_binary(id) and (id != "")
        end) |> Enum.map(fn(id) ->
          "#{provider}:#{id}"
        end)
        {provider, {:ok, rr}}

      _ ->
        {provider, :error}
    end
  catch
    _, _ -> :skip
  end
end
