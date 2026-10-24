defmodule Current.HTTP.MCPGuard do
  @moduledoc """
  Transport-level checks for `/mcp`, run by the router before the request
  body is read and before `Current.MCP.handle/1` sees anything.

  These are the HTTP-layer requirements of the MCP Streamable HTTP
  transport (revision 2025-06-18), not an authentication scheme. Who may
  call `/mcp` at all is still the job of your gateway or network rules.

    * **Origin** (all methods). A request that carries an `Origin` header
      is refused with `403` unless the origin is allowed. This is what
      stops a web page from using DNS rebinding to drive a local runtime
      from the user's own browser: binding to `127.0.0.1` alone does not.
      A request with *no* `Origin` (curl, scripts, desktop and CLI MCP
      clients) is not a browser and is let through.
    * **MCP-Protocol-Version** (all methods). If present it must be the
      one version this server implements, else `400`. If absent we do not
      guess an older version (the spec suggests assuming 2025-03-26): this
      server's behaviour does not differ between the two where it matters,
      and the `initialize` request legitimately has no header yet.
    * **Content-Type** (`POST`). Must be `application/json`, else `415`.

  ## Configuration

      config :current, :mcp,
        # Origins allowed in addition to loopback ones, exact match on
        # scheme://host[:port], case-insensitive. Default: none.
        allowed_origins: ["https://agents.internal.example.com"],
        # Accept http(s)://localhost, 127.0.0.1 and [::1] on any port.
        # Default: true. Set to false behind a gateway that terminates the
        # browser's connection under a real hostname.
        allow_loopback_origins: true

  Both are read per request.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/mcp"} = conn, _opts) do
    with :ok <- check_origin(conn),
         :ok <- check_protocol_version(conn),
         :ok <- check_content_type(conn) do
      conn
    else
      {:error, status, message} ->
        body =
          JSON.encode!(%{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: message}})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, body)
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc "Whether `origin` (the value of an `Origin` header) is allowed under the current config."
  @spec allowed_origin?(String.t()) :: boolean()
  def allowed_origin?(origin) when is_binary(origin) do
    config = Application.get_env(:current, :mcp, [])
    origin = String.downcase(origin)

    explicitly_allowed? =
      config
      |> Keyword.get(:allowed_origins, [])
      |> Enum.any?(&(String.downcase(&1) == origin))

    explicitly_allowed? or
      (Keyword.get(config, :allow_loopback_origins, true) and loopback_origin?(origin))
  end

  defp loopback_origin?(origin) do
    # An origin is scheme://host[:port] and nothing else.
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when scheme in ["http", "https"] and path in [nil, ""] ->
        host in @loopback_hosts

      _ ->
        false
    end
  end

  ## Checks

  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if allowed_origin?(origin), do: :ok, else: forbidden()
      _several -> forbidden()
    end
  end

  defp forbidden, do: {:error, 403, "Forbidden: origin not allowed"}

  defp check_protocol_version(conn) do
    supported = Current.MCP.protocol_version()

    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [^supported] ->
        :ok

      _other ->
        {:error, 400, "Unsupported MCP-Protocol-Version; this server implements #{supported}"}
    end
  end

  defp check_content_type(%Plug.Conn{method: "POST"} = conn) do
    case get_req_header(conn, "content-type") do
      [type | _] ->
        # Parse the media type and compare it exactly; a prefix match would
        # also accept application/jsonp and application/json-malicious.
        case Plug.Conn.Utils.media_type(type) do
          {:ok, "application", "json", _params} -> :ok
          _ -> unsupported()
        end

      [] ->
        unsupported()
    end
  end

  defp check_content_type(_conn), do: :ok

  defp unsupported, do: {:error, 415, "Content-Type must be application/json"}
end
