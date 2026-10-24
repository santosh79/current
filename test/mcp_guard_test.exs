defmodule Current.HTTP.MCPGuardTest do
  @moduledoc """
  The transport checks on `/mcp`, exercised on the plug alone. Not async:
  it changes the `:mcp` application env.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Current.HTTP.MCPGuard

  setup do
    previous = Application.get_env(:current, :mcp)
    on_exit(fn -> restore(previous) end)
    Application.delete_env(:current, :mcp)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:current, :mcp)
  defp restore(value), do: Application.put_env(:current, :mcp, value)

  defp call(method \\ :post, path \\ "/mcp", headers \\ [{"content-type", "application/json"}]) do
    conn = conn(method, path, "{}")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    MCPGuard.call(conn, MCPGuard.init([]))
  end

  defp passed?(conn), do: not conn.halted

  describe "Origin" do
    test "no Origin header: not a browser, let through" do
      assert passed?(call())
    end

    test "loopback origins pass by default, on any port and scheme" do
      for origin <- [
            "http://localhost",
            "http://localhost:3000",
            "https://localhost:8443",
            "http://127.0.0.1:6274",
            "http://[::1]:5173",
            "HTTP://LOCALHOST:3000"
          ] do
        conn = call(:post, "/mcp", [{"content-type", "application/json"}, {"origin", origin}])
        assert passed?(conn), "#{origin} should be allowed"
      end
    end

    test "any other origin is refused with 403 and a JSON-RPC error" do
      for origin <- [
            "https://evil.example.com",
            "http://localhost.evil.com",
            "http://127.0.0.1.evil.com",
            "http://evil.com:3000",
            "http://localhost@evil.com",
            "http://localhost/path",
            "ftp://localhost",
            "file://",
            "null",
            ""
          ] do
        conn = call(:post, "/mcp", [{"content-type", "application/json"}, {"origin", origin}])
        assert conn.halted, "#{inspect(origin)} should be refused"
        assert conn.status == 403
        assert %{"error" => %{"code" => -32600}, "id" => nil} = JSON.decode!(conn.resp_body)
      end
    end

    test "applies to every method, not just POST" do
      for method <- [:get, :delete, :options, :post] do
        conn = call(method, "/mcp", [{"origin", "https://evil.example.com"}])
        assert conn.status == 403, "#{method}"
      end
    end

    test "two Origin headers are refused" do
      conn =
        conn(:post, "/mcp", "{}")
        |> put_req_header("content-type", "application/json")
        |> Map.update!(
          :req_headers,
          &[{"origin", "http://localhost"}, {"origin", "http://localhost"} | &1]
        )
        |> MCPGuard.call([])

      assert conn.status == 403
    end

    test "configured origins are allowed (exact match, case-insensitive), others still are not" do
      Application.put_env(:current, :mcp, allowed_origins: ["https://Agents.Example.com"])

      ok =
        call(:post, "/mcp", [
          {"content-type", "application/json"},
          {"origin", "https://agents.example.com"}
        ])

      assert passed?(ok)

      for origin <- [
            "https://agents.example.com:8443",
            "http://agents.example.com",
            "https://x.example.com"
          ] do
        conn = call(:post, "/mcp", [{"content-type", "application/json"}, {"origin", origin}])
        assert conn.status == 403, origin
      end
    end

    test "loopback can be switched off" do
      Application.put_env(:current, :mcp, allow_loopback_origins: false)

      conn =
        call(:post, "/mcp", [
          {"content-type", "application/json"},
          {"origin", "http://localhost:3000"}
        ])

      assert conn.status == 403
    end

    test "origin check happens before anything else (a bad origin with a bad version is 403)" do
      conn =
        call(:post, "/mcp", [
          {"content-type", "text/plain"},
          {"origin", "https://evil.example.com"},
          {"mcp-protocol-version", "1999-01-01"}
        ])

      assert conn.status == 403
    end
  end

  describe "MCP-Protocol-Version" do
    test "absent is fine (the initialize request has none yet)" do
      assert passed?(call())
    end

    test "the implemented version passes" do
      headers = [
        {"content-type", "application/json"},
        {"mcp-protocol-version", Current.MCP.protocol_version()}
      ]

      assert passed?(call(:post, "/mcp", headers))
    end

    test "anything else is 400, including versions the spec knows" do
      for version <- ["2024-11-05", "2025-03-26", "2025-11-25", "2026-07-28", "garbage", ""] do
        conn =
          call(:post, "/mcp", [
            {"content-type", "application/json"},
            {"mcp-protocol-version", version}
          ])

        assert conn.halted and conn.status == 400, version
        assert conn.resp_body =~ Current.MCP.protocol_version()
      end
    end
  end

  describe "Content-Type" do
    test "POST needs application/json (parameters allowed)" do
      assert passed?(call(:post, "/mcp", [{"content-type", "application/json; charset=utf-8"}]))

      assert passed?(call(:post, "/mcp", [{"content-type", "Application/JSON"}]))

      for type <- [
            "text/plain",
            "application/x-www-form-urlencoded",
            "application/jsonp",
            "application/json-malicious",
            "application/jsonx; charset=utf-8",
            "garbage",
            ""
          ] do
        conn = call(:post, "/mcp", [{"content-type", type}])
        assert conn.status == 415, type
      end

      assert call(:post, "/mcp", []).status == 415
    end

    test "GET is not subject to it" do
      assert passed?(call(:get, "/mcp", []))
    end
  end

  test "other paths are untouched, whatever the headers" do
    conn =
      call(:post, "/v1/tasks", [
        {"origin", "https://evil.example.com"},
        {"mcp-protocol-version", "x"}
      ])

    assert passed?(conn)
  end
end
