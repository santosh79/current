defmodule Current.HTTP.RequestGuard do
  @moduledoc """
  Browser-facing transport checks for **every** route, run by the router
  before the request body is read.

  Binding to `127.0.0.1` does not stop a web page from reaching the runtime
  through DNS rebinding: once the page's domain rebinds to `127.0.0.1`, its
  requests are same-origin, so CORS does not apply. The `/v1/*` routes can
  do everything MCP can, including approve and apply (which write to the
  project), so they need the same protection `/mcp` has.

    * **Host** (all routes, all methods). The `Host` header must be
      `localhost`, `127.0.0.1` or `[::1]` together with the port the server
      is configured to listen on, or be listed in `allowed_hosts`. A
      rebound page still sends its own domain as `Host`, so this is what
      defeats the attack. A request with *no* `Host` header (HTTP/1.0
      tools) is not a browser and is let through. Several `Host` headers
      are refused.
    * **Origin** (all routes except `/mcp`, all methods). A request with an
      `Origin` header is refused unless the origin is allowed; a request
      with no `Origin` is let through. This is the same rule
      `Current.HTTP.MCPGuard` applies to `/mcp`, which keeps doing so itself
      so that its errors stay JSON-RPC. See
      `Current.HTTP.MCPGuard.allowed_origin?/1`.

  Refusals are `403`. On `/mcp` the body is a JSON-RPC error; elsewhere it
  is the usual `{"error": {"code": ..., "message": ...}}`.

  ## Configuration

      config :current, :http,
        # Extra Host header values to accept, exact match on host[:port],
        # case-insensitive. Use this behind a proxy or when you reach the
        # runtime under another name. Default: none.
        allowed_hosts: ["current.internal.example.com:4000"]

  Read per request. Origins are configured under `config :current, :mcp`
  (`allowed_origins`, `allow_loopback_origins`), and apply to all routes.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback_hosts ["localhost", "127.0.0.1", "[::1]"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with :ok <- check_host(conn),
         :ok <- check_origin(conn) do
      conn
    else
      {:error, message} -> refuse(conn, message)
    end
  end

  @doc """
  Whether `host` (the value of a `Host` header) is allowed under the current
  config: a loopback name with the configured port, or an `allowed_hosts`
  entry. Compared exactly and case-insensitively.
  """
  @spec allowed_host?(String.t()) :: boolean()
  def allowed_host?(host) when is_binary(host) do
    host = String.downcase(host)
    port = Current.HTTP.Server.port()

    loopback? = Enum.any?(@loopback_hosts, &(host == "#{&1}:#{port}"))

    loopback? or
      :current
      |> Application.get_env(:http, [])
      |> Keyword.get(:allowed_hosts, [])
      |> Enum.any?(&(String.downcase(&1) == host))
  end

  ## Checks

  defp check_host(conn) do
    case get_req_header(conn, "host") do
      [] -> :ok
      [host] -> if allowed_host?(host), do: :ok, else: {:error, "Forbidden: host not allowed"}
      _several -> {:error, "Forbidden: host not allowed"}
    end
  end

  # /mcp checks Origin itself (Current.HTTP.MCPGuard) to keep JSON-RPC errors.
  defp check_origin(%Plug.Conn{request_path: "/mcp"}), do: :ok

  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        if Current.HTTP.MCPGuard.allowed_origin?(origin),
          do: :ok,
          else: {:error, "Forbidden: origin not allowed"}

      _several ->
        {:error, "Forbidden: origin not allowed"}
    end
  end

  ## Response

  defp refuse(conn, message) do
    body =
      if conn.request_path == "/mcp" do
        %{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: message}}
      else
        %{error: %{code: "forbidden", message: message}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, JSON.encode!(body))
    |> halt()
  end
end
