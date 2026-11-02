defmodule Current.ModelCatalogStartupTest.Client do
  @moduledoc false
  def provider, do: "local"

  def list_models(_timeout) do
    send(Application.fetch_env!(:current, :catalog_test_owner), :discover)
    {:ok, ["coder", "coder", "tag:latest", ""]}
  end
end

defmodule Current.ModelCatalogStartupTest do
  use ExUnit.Case, async: false

  import Current.TestHelpers, only: [put_env: 2]

  alias Current.ModelCatalog
  alias Current.ModelCatalogStartupTest.Client

  setup do
    put_env(:model_catalog_clients, [Client])
    put_env(:catalog_test_owner, self())
    :ok
  end

  test "discovers once at startup and serves an ETS snapshot" do
    pid = start_supervised!(ModelCatalog)
    assert_receive :discover, 1_000

    eventually(fn ->
      ModelCatalog.all(pid) == ["local:coder", "local:tag:latest"]
    end)

    assert ModelCatalog.available?(pid, "local:coder")
    refute ModelCatalog.available?(pid, "local:missing")
    refute_receive :discover, 50
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
