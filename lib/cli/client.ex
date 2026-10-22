defmodule Current.CLI.Client do
  @moduledoc """
  Client-side transport: how the CLI reaches a running Current runtime,
  which is over its HTTP API (`Current.HTTP.Router`). It speaks plain
  HTTP/JSON through OTP's `:httpc`, so the escript needs no dependencies,
  and turns every failure into an `{:error, reason}` value instead of an
  exception.

  The runtime is at `http://127.0.0.1:4000` unless `CURRENT_URL` says
  otherwise (a bare `host:port` gets `http://`). `bin/current-server`
  starts the runtime listening there; see `Current.HTTP.Server` for how it
  is configured.

  Answers come back as decoded JSON: maps with string keys, exactly the
  documents the API serves. Nothing is turned back into runtime structs,
  so a client written in any language sees the same data the CLI does.

  `local/0` sends requests to `Current.HTTP.Router` in this VM, through
  `Plug.Test`, instead of over a socket. It is the real router, minus the
  network, which is what tests use.

  ## Errors

    * `:runtime_unavailable` -- nothing is listening at the URL;
    * `{:http_failed, reason}` -- the request failed on the way (`:timeout`,
      a TLS error, ...);
    * `{:api_error, %{status:, code:, message:, details:}}` -- the runtime
      answered with an error; `code` is the API's stable code (for example
      `"not_found"` or `"ambiguous_id"`) and `details` is a map with string
      keys or nil;
    * `{:bad_response, status}` -- the answer wasn't something this client
      understands (a proxy's error page, say).
  """

  @default_url "http://127.0.0.1:4000"
  @request_timeout_ms 30_000
  @connect_timeout_ms 3_000

  @enforce_keys [:url, :send]
  defstruct [:url, :send]

  @type t :: %__MODULE__{
          url: String.t(),
          send: (:get | :post, String.t(), binary() | nil -> raw())
        }

  @typep raw :: {:ok, pos_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}

  @type api_error :: %{
          status: pos_integer(),
          code: String.t() | nil,
          message: String.t(),
          details: map() | nil
        }

  @type error ::
          :runtime_unavailable
          | {:http_failed, term()}
          | {:api_error, api_error()}
          | {:bad_response, pos_integer()}

  ## Connecting

  @doc """
  A client for the runtime at `base_url/0`. Nothing is sent yet, so a
  runtime that isn't running shows up as `:runtime_unavailable` on the
  first request.
  """
  @spec connect() :: {:ok, t()}
  def connect do
    url = base_url()
    {:ok, %__MODULE__{url: url, send: fn method, path, body -> http(url, method, path, body) end}}
  end

  @doc "A client for `Current.HTTP.Router` in this VM, without a socket."
  @spec local() :: {:ok, t()}
  def local, do: {:ok, %__MODULE__{url: "(in-process)", send: &plug/3}}

  @doc "The runtime's base URL: `CURRENT_URL`, or #{@default_url}."
  @spec base_url() :: String.t()
  def base_url do
    case System.get_env("CURRENT_URL") do
      value when value in [nil, ""] ->
        @default_url

      value ->
        value = String.trim_trailing(value, "/")
        if String.contains?(value, "://"), do: value, else: "http://" <> value
    end
  end

  ## The API

  @doc """
  Submits a task. `params` has `:prompt`, `:model`, `:dir` and `:mode`
  (`"plan"` or `"apply"`), and optionally `:timeout_ms`. Returns its id.
  """
  @spec submit_task(t(), map()) :: {:ok, String.t()} | {:error, error()}
  def submit_task(client, params) do
    params = Map.reject(params, fn {_key, value} -> is_nil(value) end)

    with {:ok, %{"task_id" => task_id}} <- json(client, :post, "/v1/tasks", params) do
      {:ok, task_id}
    end
  end

  def workflow(client, id), do: json(client, :get, "/v1/workflows/" <> segment(id))
  def proposal(client, id), do: json(client, :get, "/v1/proposals/" <> segment(id))

  @doc """
  Live activity of a workflow after `after_seq`; see
  `Current.API.activity/3`. `workflow_id` is a full id.
  """
  def activity(client, workflow_id, epoch, after_seq) do
    params = [epoch: epoch, after_seq: after_seq]
    json(client, :get, "/v1/workflows/" <> segment(workflow_id) <> "/activity" <> query(params))
  end

  @doc "The `current.review/v1` document for a proposal (`opts` has `:max_lines` and `:raw`)."
  def review(client, id, opts) do
    params = [max_lines: opts[:max_lines], raw: if(opts[:raw], do: true)]
    json(client, :get, "/v1/proposals/" <> segment(id) <> "/review" <> query(params))
  end

  @doc "Approves a proposal. `metadata` has `:message` and `:reviewed_by`."
  def approve(client, id, metadata), do: decide(client, id, "approve", metadata)
  def reject(client, id, metadata), do: decide(client, id, "reject", metadata)

  @doc """
  Sends a proposal back for a new one. `feedback` is what to change;
  `metadata` has `:reviewed_by`. Answers the workflow id.
  """
  @spec revise(t(), String.t(), map()) :: {:ok, String.t()} | {:error, error()}
  def revise(client, id, %{feedback: feedback} = metadata) do
    body = %{feedback: feedback, reviewed_by: metadata[:reviewed_by]}
    body = Map.reject(body, fn {_key, value} -> is_nil(value) end)

    with {:ok, %{"workflow_id" => workflow_id}} <-
           json(client, :post, "/v1/proposals/" <> segment(id) <> "/revise", body) do
      {:ok, workflow_id}
    end
  end

  @spec apply_proposal(t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def apply_proposal(client, id) do
    with {:ok, %{"workflow_id" => workflow_id}} <-
           json(client, :post, "/v1/proposals/" <> segment(id) <> "/apply", %{}) do
      {:ok, workflow_id}
    end
  end

  @doc "An artifact's full id and exact bytes."
  @spec artifact(t(), String.t()) :: {:ok, String.t(), binary()} | {:error, error()}
  def artifact(client, id) do
    with {:ok, headers, body} <- request(client, :get, "/v1/artifacts/" <> segment(id), nil) do
      {:ok, header(headers, "x-current-artifact-id") || id, body}
    end
  end

  @spec models(t()) :: {:ok, [String.t()]} | {:error, error()}
  def models(client) do
    with {:ok, %{"models" => models}} <- json(client, :get, "/v1/models"), do: {:ok, models}
  end

  @spec health(t()) :: {:ok, map()} | {:error, error()}
  def health(client) do
    with {:ok, %{"status" => _} = health} <- json(client, :get, "/v1/health"), do: {:ok, health}
  end

  defp decide(client, id, verb, metadata) do
    body = Map.take(metadata, [:message, :reviewed_by])

    with {:ok, %{"workflow_id" => workflow_id}} <-
           json(client, :post, "/v1/proposals/" <> segment(id) <> "/" <> verb, body) do
      {:ok, workflow_id}
    end
  end

  ## Requests

  # An id is a path segment. Colons ("sha256:...") are left alone.
  defp segment(id), do: URI.encode(id, &(URI.char_unreserved?(&1) or &1 == ?:))

  defp query(pairs) do
    case for({key, value} <- pairs, value != nil, do: {key, value}) do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end

  defp json(client, method, path, body \\ nil) do
    with {:ok, _headers, raw} <- request(client, method, path, body && JSON.encode!(body)) do
      case JSON.decode(raw) do
        {:ok, document} -> {:ok, document}
        {:error, _reason} -> {:error, {:bad_response, 200}}
      end
    end
  end

  defp request(%__MODULE__{send: send}, method, path, body) do
    case send.(method, path, body) do
      {:ok, status, headers, raw} when status in 200..299 -> {:ok, headers, raw}
      {:ok, status, _headers, raw} -> {:error, api_error(status, raw)}
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  defp api_error(status, raw) do
    with {:ok, %{"error" => %{"message" => message} = error}} <- JSON.decode(raw) do
      {:api_error,
       %{
         status: status,
         code: error["code"],
         message: message,
         details: error["details"]
       }}
    else
      _ -> {:bad_response, status}
    end
  end

  # Nothing listening, or no way to reach the host: the runtime isn't up.
  defp transport_error({:failed_connect, [_to_address, {_, _, :timeout}]}),
    do: {:http_failed, :timeout}

  defp transport_error({:failed_connect, _details}), do: :runtime_unavailable
  defp transport_error(:timeout), do: {:http_failed, :timeout}
  defp transport_error(reason), do: {:http_failed, reason}

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  ## Transports

  defp http(base_url, method, path, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    url = String.to_charlist(base_url <> path)
    headers = [{~c"accept", ~c"application/json"}]

    request =
      case body do
        nil -> {url, headers}
        body -> {url, headers, ~c"application/json", body}
      end

    http_options =
      [timeout: @request_timeout_ms, connect_timeout: @connect_timeout_ms, autoredirect: false] ++
        tls_options(base_url)

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        {:ok, status, Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An https URL (a gateway in front of the runtime) is verified against
  # the system's CA certificates.
  defp tls_options("https://" <> _) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]
  end

  defp tls_options(_url), do: []

  defp plug(method, path, body) do
    conn = Plug.Test.conn(method, path, body)

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    conn = Current.HTTP.Router.call(conn, Current.HTTP.Router.init([]))

    {:ok, conn.status, conn.resp_headers, IO.iodata_to_binary(conn.resp_body)}
  end
end
