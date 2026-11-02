defmodule Current.LLMClient.HTTP do
  @moduledoc """
  Shared transport for model providers (HTTPS except explicitly local endpoints).

  Provider modules may be configured with `base_url`, including the API version
  path, for example:

      config :current, Current.LLMClient.OpenAI,
        base_url: "https://api.openai.com/v1"

  Overrides are read per call and must use HTTPS for hosted providers. The
  The OpenAICompatible provider additionally permits HTTP. These are trusted
  operator settings: prompts and API keys are sent to the configured host in
  cleartext when HTTP is selected.

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
      _ -> {:error, :invalid_provider_base_url}
    end
  end

  defp permitted_uri(_provider, %URI{scheme: "https"} = uri), do: {:ok, uri}
  defp permitted_uri(Current.LLMClient.OpenAICompatible, %URI{scheme: "http"} = uri), do: {:ok, uri}
  defp permitted_uri(_provider, _uri), do: {:error, :invalid_provider_base_url}

  def request(method, request, timeout_ms) do
    with {:ok, transport_options} <- transport_options(elem(request, 0)) do
      options =
        [
          connect_timeout: min(@connect_timeout_ms, timeout_ms),
          timeout: timeout_ms,
          autoredirect: false
        ] ++ transport_options

      method
      |> :httpc.request(request, options, body_format: :binary)
      |> response()
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
       when status in 200..299,
       do: {:ok, body}

  defp response({:ok, {{_version, status, _reason}, _headers, body}}),
    do: {:error, {:http_error, status, body}}

  defp response({:error, :timeout}), do: {:error, :timeout}
  defp response({:error, reason}), do: {:error, {:http_error, reason}}
end
