defmodule Current.ModelCatalogTest.Client do
  @moduledoc false
  def provider, do: "local"

  def list_models(_timeout) do
    send(Application.fetch_env!(:current, :catalog_test_owner), {:discover, self()})

    receive do
      {:models, models} -> {:ok, models}
      :fail -> {:error, :unreachable}
    end
  end
end

defmodule Current.ModelCatalogTest.RaisingClient do
  @moduledoc false
  def provider, do: "broken"
  def list_models(_timeout), do: raise("provider exploded")
end

defmodule Current.ModelCatalogTest do
  use ExUnit.Case, async: false

  import Current.TestHelpers, only: [put_env: 2]

  alias Current.ModelCatalog
  alias Current.ModelCatalogTest.{Client, RaisingClient}

  setup do
    put_env(:model_catalog_clients, [Client])
    put_env(:catalog_test_owner, self())
    :ok
  end

  # Startup discovery is intentionally asynchronous. A query should never
  # initiate discovery or wait for the provider.
  test "reads are immediate snapshots, even during startup discovery" do
    pid = start_supervised!(ModelCatalog)
    assert_receive {:discover, worker}, 1_000

    assert ModelCatalog.all(pid) == []
    refute ModelCatalog.available?(pid, "local:coder")
    refute_receive {:discover, _}, 50

    send(worker, {:models, ["coder", "coder", "tag:latest"]})
    eventually(fn -> ModelCatalog.all(pid) == ["local:coder", "local:tag:latest"] end)
    assert ModelCatalog.available?(pid, "local:coder")
  end

  test "explicit refresh performs discovery outside catalog and publishes new models" do
    pid = start_supervised!(ModelCatalog)
    assert_receive {:discover, first}, 1_000
    send(first, {:models, ["old"]})
    eventually(fn -> ModelCatalog.all(pid) == ["local:old"] end)

    refresh = Task.async(fn -> ModelCatalog.refresh(pid) end)
    assert_receive {:discover, worker}, 1_000
    # While network I/O is pending, queries still read the old snapshot.
    assert ModelCatalog.all(pid) == ["local:old"]
    refute ModelCatalog.available?(pid, "local:new")
    send(worker, {:models, ["new"]})
    assert Task.await(refresh, 3_000) == ["local:new"]
    assert ModelCatalog.all(pid) == ["local:new"]
    refute ModelCatalog.available?(pid, "local:old")
  end

  test "failed discovery keeps existing models; empty successful discovery clears them" do
    pid = start_supervised!(ModelCatalog)
    assert_receive {:discover, first}, 1_000
    send(first, {:models, ["a"]})
    eventually(fn -> ModelCatalog.all(pid) == ["local:a"] end)

    refresh = Task.async(fn -> ModelCatalog.refresh(pid) end)
    assert_receive {:discover, second}, 1_000
    send(second, :fail)
    assert Task.await(refresh, 3_000) == ["local:a"]

    refresh = Task.async(fn -> ModelCatalog.refresh(pid) end)
    assert_receive {:discover, third}, 1_000
    send(third, {:models, []})
    assert Task.await(refresh, 3_000) == []
  end

  test "a failing provider does not crash the catalog" do
    put_env(:model_catalog_clients, [Client, RaisingClient])
    pid = start_supervised!(ModelCatalog)
    assert_receive {:discover, worker}, 1_000
    send(worker, {:models, ["a"]})
    eventually(fn -> ModelCatalog.all(pid) == ["local:a"] end)
    assert Process.alive?(pid)

    refresh = Task.async(fn -> ModelCatalog.refresh(pid) end)
    assert_receive {:discover, worker}, 1_000
    send(worker, {:models, ["b"]})
    assert Task.await(refresh, 3_000) == ["local:b"]
    assert Process.alive?(pid)
  end

  test "an explicitly disabled local provider contributes no models" do
    put_env(:model_catalog_clients, [Current.LLMClient.OpenAICompatible])
    saved = System.get_env("CURRENT_LOCAL_LLM_BASE_URL")
    System.delete_env("CURRENT_LOCAL_LLM_BASE_URL")

    on_exit(fn ->
      if saved,
        do: System.put_env("CURRENT_LOCAL_LLM_BASE_URL", saved),
        else: System.delete_env("CURRENT_LOCAL_LLM_BASE_URL")
    end)

    pid = start_supervised!(ModelCatalog)

    # Simulate models discovered before the operator disabled the endpoint.
    assert GenServer.call(pid, {:replace, [{"local", {:ok, ["local:old"]}}]}) ==
             ["local:old"]

    assert ModelCatalog.refresh(pid) == []
    assert ModelCatalog.all(pid) == []
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
