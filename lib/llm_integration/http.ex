defmodule Current.LLMClient.HTTP do
  @moduledoc """
  Shared transport for model providers (HTTPS except explicitly local endpoints).

  Provider modules may be configured with `base_url`, including the API version
  path, for example:

      config :current, Current.LLMClient.OpenAI,
        base_url: "https://api.openai.com/v1"

  Overrides are read per call and must use HTTPS for hosted providers. The
  OpenAICompatible provider additionally permits HTTP to literal loopback/RFC1918
  or IPv6 unique-local addresses. `localhost` is pinned to 127.0.0.1. Other HTTP
  hostnames require CURRENT_LOCAL_LLM_ALLOW_HTTP_HOSTNAMES=true; public IP literals
  still require HTTPS. These are trusted operator settings: prompts and API keys
  will be sent to the configured host, in cleartext when HTTP is selected.

  The trust anchors default to the operating system store. For hermetic tests
  (or an operator pinning a private CA) a non-empty list of DER certificates may
  be set in the application environment:

      config :current, Current.LLMClient.HTTP, cacerts: [der, ...]

  This is application configuration, read on every request. It is not
  request-local state: while it is set, every request made by any process
  trusts exactly these certificates instead of the OS store. Peer and hostname
  verification stay on regardless; anything other than a non-empty list is
  ignored and the OS store is used.
  """

  @connect_timeout_ms 10_000

  def endpoint(provider, default_base_url, path) do
    base_url =
      :current
      |> Application.get_env(provider, [])
      |> Keyword.get(:base_url, default_base_url)

    with true <- is_binary(base_url),
         {:ok, uri} <- URI.new(base_url),
         %URI{host: host, userinfo: nil, query: nil, fragment: nil}
         when is_binary(host) and host != "" <- uri,
         {:ok, uri} <- permitted_uri(provider, uri) do
      {:ok, String.to_charlist(String.trim_trailing(URI.to_string(uri), "/") <> path)}
    else
      {:error, {:insecure_local_llm_url, _}} = error -> error
      _ -> {:error, :invalid_provider_base_url}
    end
  end

  defp permitted_uri(_provider, %URI{scheme: "https"} = uri), do: {:ok, uri}

  defp permitted_uri(Current.LLMClient.OpenAICompatible, %URI{scheme: "http", host: host} = uri) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        if private_address?(address), do: {:ok, uri}, else: insecure_local_url()

      {:error, _} ->
        cond do
          String.downcase(host) == "localhost" -> {:ok, %{uri | host: "127.0.0.1"}}
          System.get_env("CURRENT_LOCAL_LLM_ALLOW_HTTP_HOSTNAMES") == "true" -> {:ok, uri}
          true -> insecure_local_url()
        end
    end
  end

  defp permitted_uri(_provider, _uri), do: {:error, :invalid_provider_base_url}

  defp insecure_local_url do
    {:error,
     {:insecure_local_llm_url,
      "Use HTTPS or a loopback/private IP. For a trusted Docker/LAN hostname only, " <>
        "explicitly set CURRENT_LOCAL_LLM_ALLOW_HTTP_HOSTNAMES=true (unencrypted prompts and keys)."}}
  end

  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({172, b, _, _}) when b in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private_address?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  defp private_address?(_), do: false

  @max_response_bytes 8_388_608

  # The same URL policy is checked at the actual request boundary. Clients
  # without an explicit local provider cannot issue plaintext HTTP requests.
  def request(method, request, timeout_ms, provider \\ nil) do
    with {:ok, uri} <- URI.new(to_string(elem(request, 0))),
         %URI{host: host, userinfo: nil, query: nil, fragment: nil}
         when is_binary(host) and host != "" <- uri,
         {:ok, uri} <- permitted_uri(provider, uri),
         {:ok, transport_options} <- transport_options(URI.to_string(uri)) do
      endpoint = String.to_charlist(URI.to_string(uri))
      request = put_elem(request, 0, endpoint)

      options =
        [
          connect_timeout: min(@connect_timeout_ms, timeout_ms),
          timeout: timeout_ms,
          autoredirect: false
        ] ++ transport_options

      method
      |> :httpc.request(request, options, [body_format: :binary] ++ socket_options(endpoint))
      |> response()
    else
      {:error, {:insecure_local_llm_url, _}} = error -> error
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_base_url}
    end
  end

  # httpc connects over IPv4 unless told otherwise, which can never reach an
  # IPv6 literal such as http://[::1]:11434. Asking for IPv6 per request
  # (which also means a connection of its own) leaves every other request alone.
  defp socket_options(endpoint) do
    with host when is_binary(host) <- URI.parse(to_string(endpoint)).host,
         {:ok, address} when tuple_size(address) == 8 <-
           :inet.parse_address(String.to_charlist(host)) do
      [socket_opts: [ipfamily: :inet6]]
    else
      _ -> []
    end
  end

  # Plain HTTP needs no CA store. HTTPS always retains peer/name verification.
  defp transport_options(endpoint) do
    case URI.parse(to_string(endpoint)).scheme do
      "http" ->
        {:ok, []}

      _ ->
        with {:ok, ssl} <- ssl_opts(cacerts_loader()), do: {:ok, [ssl: ssl]}
    end
  end

  defp cacerts_loader do
    case :current |> Application.get_env(__MODULE__, []) |> Keyword.get(:cacerts) do
      [_ | _] = cacerts -> fn -> cacerts end
      _ -> &:public_key.cacerts_get/0
    end
  end

  # The injectable loader keeps missing-store tests independent of the host's
  # global public_key CA cache. Production always uses the OS store.
  @doc false
  def ssl_opts(load_cacerts \\ &:public_key.cacerts_get/0) do
    with {:ok, cacerts} <- load_cacerts(load_cacerts) do
      {:ok,
       [
         verify: :verify_peer,
         cacerts: cacerts,
         versions: [:"tlsv1.2", :"tlsv1.3"],
         customize_hostname_check: [
           match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
         ]
       ]}
    end
  end

  defp load_cacerts(loader) do
    case loader.() do
      [_ | _] = cacerts -> {:ok, cacerts}
      _ -> {:error, :no_ca_certificates}
    end
  rescue
    _ -> {:error, :no_ca_certificates}
  end

  defp response({:ok, {{_version, status, _reason}, _headers, body}})
       when status in 200..299 and byte_size(body) <= @max_response_bytes,
       do: {:ok, body}

  defp response({:ok, {{_version, status, _reason}, _headers, _body}})
       when status in 200..299,
       do: {:error, :response_too_large}

  defp response({:ok, {{_version, status, _reason}, _headers, body}}),
    do: {:error, {:http_error, status, safe_error(body)}}

  # Only retain a bounded error category, not arbitrary server output (which
  # may echo prompts, credentials or other sensitive contents).
  defp safe_error(body) when is_binary(body) do
    sample = binary_part(body, 0, min(byte_size(body), 16_384))

    if String.valid?(sample) do
      text = String.downcase(sample)

      cond do
        String.contains?(text, [
          "context_length",
          "context length",
          "context window",
          "too many tokens",
          "maximum context"
        ]) ->
          "context length exceeded"

        String.contains?(text, ["response_format", "json_schema"]) ->
          "unsupported response_format"

        true ->
          ""
      end
    else
      ""
    end
  end

  defp response({:error, :timeout}), do: {:error, :timeout}
  defp response({:error, reason}), do: {:error, {:http_error, reason}}
end
