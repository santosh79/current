defmodule Current.HTTP.RequestGuardTest do
  @moduledoc """
  Host and Origin checks on every route (DNS rebinding), exercised through
  the router. Not async: it changes the `:http` and `:mcp` application env.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Current.HTTP.Router

  setup do
    http = Application.get_env(:current, :http)
    mcp = Application.get_env(:current, :mcp)

    on_exit(fn ->
      restore(:http, http)
      restore(:mcp, mcp)
    end)

    Application.delete_env(:current, :mcp)
    {:ok, port: Current.HTTP.Server.port(), http: http}
  end

  defp restore(key, nil), do: Application.delete_env(:current, key)
  defp restore(key, value), do: Application.put_env(:current, key, value)

  defp call(method, path, headers) do
    conn = conn(method, path, "")

    conn =
      Enum.reduce(headers, conn, fn
        {"host", value}, c ->
          Map.update!(c, :req_headers, &[{"host", value} | &1])

        {name, value}, c ->
          put_req_header(c, name, value)
      end)

    Router.call(conn, Router.init([]))
  end

  # put_req_header replaces, so repeated headers are added by hand.
  defp call_repeated(method, path, name, values) do
    conn = conn(method, path, "")

    conn =
      Map.update!(conn, :req_headers, fn headers ->
        Enum.map(values, &{name, &1}) ++ headers
      end)

    Router.call(conn, Router.init([]))
  end

  defp refused?(conn), do: conn.halted and conn.status == 403

  describe "Host" do
    test "loopback names on the configured port pass", %{port: port} do
      for host <- [
            "localhost:#{port}",
            "127.0.0.1:#{port}",
            "[::1]:#{port}",
            "LOCALHOST:#{port}"
          ] do
        assert call(:get, "/v1/health", [{"host", host}]).status == 200, host
      end
    end

    test "no Host header: not a browser, let through" do
      assert call(:get, "/v1/health", []).status == 200
    end

    test "anything else is refused with 403", %{port: port} do
      for host <- [
            "evil.example.com",
            "evil.example.com:#{port}",
            "localhost:#{port + 1}",
            "localhost",
            "127.0.0.1.evil.com:#{port}",
            "localhost.evil.com:#{port}",
            "localhost:abc",
            "localhost:#{port}:1",
            "[::1",
            ""
          ] do
        conn = call(:get, "/v1/health", [{"host", host}])
        assert refused?(conn), inspect(host)
      end
    end

    test "applies to every route and method, including writes", %{port: _port} do
      for {method, path} <- [
            {:get, "/v1/models"},
            {:get, "/v1/proposals/abcdef"},
            {:post, "/v1/tasks"},
            {:post, "/v1/proposals/abcdef/approve"},
            {:post, "/v1/proposals/abcdef/apply"},
            {:get, "/v1/nope"}
          ] do
        conn = call(method, path, [{"host", "evil.example.com"}])
        assert refused?(conn), "#{method} #{path}"
      end
    end

    test "two Host headers are refused", %{port: port} do
      conn = call_repeated(:get, "/v1/health", "host", ["localhost:#{port}", "localhost:#{port}"])
      assert refused?(conn)
    end

    test "the refusal is the usual JSON error on /v1" do
      conn = call(:get, "/v1/health", [{"host", "evil.example.com"}])

      assert %{"error" => %{"code" => "forbidden", "message" => message}} =
               JSON.decode!(conn.resp_body)

      assert message =~ "host"
    end

    test "the refusal is a JSON-RPC error on /mcp" do
      conn =
        call(:post, "/mcp", [
          {"host", "evil.example.com"},
          {"content-type", "application/json"}
        ])

      assert refused?(conn)
      assert %{"error" => %{"code" => -32600}, "id" => nil} = JSON.decode!(conn.resp_body)
    end

    test "/mcp with a loopback host gets past the guard", %{port: port} do
      conn = call(:get, "/mcp", [{"host", "localhost:#{port}"}])
      assert conn.status == 405
    end

    test "allowed_hosts adds exact, case-insensitive matches; loopback still works", %{
      port: port,
      http: http
    } do
      Application.put_env(
        :current,
        :http,
        Keyword.put(http || [], :allowed_hosts, ["Current.Internal.Example.com:443"])
      )

      assert call(:get, "/v1/health", [{"host", "current.internal.example.com:443"}]).status ==
               200

      assert call(:get, "/v1/health", [{"host", "localhost:#{port}"}]).status == 200

      for host <- [
            "current.internal.example.com",
            "current.internal.example.com:444",
            "x.current.internal.example.com:443"
          ] do
        assert refused?(call(:get, "/v1/health", [{"host", host}])), host
      end
    end
  end

  describe "Origin" do
    test "no Origin header: not a browser, let through" do
      assert call(:get, "/v1/health", []).status == 200
    end

    test "loopback origins pass by default" do
      for origin <- ["http://localhost:3000", "http://127.0.0.1:6274", "http://[::1]:5173"] do
        assert call(:get, "/v1/health", [{"origin", origin}]).status == 200, origin
      end
    end

    test "any other origin is refused on /v1 routes, whatever the method" do
      for origin <- [
            "https://evil.example.com",
            "http://localhost.evil.com",
            "http://localhost@evil.com",
            "null",
            ""
          ],
          {method, path} <- [
            {:get, "/v1/health"},
            {:post, "/v1/tasks"},
            {:post, "/v1/proposals/abcdef/apply"}
          ] do
        conn = call(method, path, [{"origin", origin}])
        assert refused?(conn), "#{method} #{path} #{inspect(origin)}"

        assert %{"error" => %{"code" => "forbidden", "message" => message}} =
                 JSON.decode!(conn.resp_body)

        assert message =~ "origin"
      end
    end

    test "two Origin headers are refused" do
      conn = call_repeated(:get, "/v1/health", "origin", ["http://localhost", "http://localhost"])
      assert refused?(conn)
    end

    test "configured origins apply to /v1 routes too" do
      Application.put_env(:current, :mcp, allowed_origins: ["https://Agents.Example.com"])

      assert call(:get, "/v1/health", [{"origin", "https://agents.example.com"}]).status == 200
      assert refused?(call(:get, "/v1/health", [{"origin", "https://x.example.com"}]))
    end

    test "loopback origins can be switched off for /v1 routes" do
      Application.put_env(:current, :mcp, allow_loopback_origins: false)
      assert refused?(call(:get, "/v1/health", [{"origin", "http://localhost:3000"}]))
    end

    test "on /mcp the origin is still refused by MCPGuard, with a JSON-RPC error" do
      conn =
        call(:post, "/mcp", [
          {"origin", "https://evil.example.com"},
          {"content-type", "application/json"}
        ])

      assert refused?(conn)
      assert %{"error" => %{"code" => -32600}, "id" => nil} = JSON.decode!(conn.resp_body)
    end
  end
end
