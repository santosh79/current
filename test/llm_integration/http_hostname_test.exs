defmodule Current.LLMIntegration.HTTPHostnameTest do
  @moduledoc """
  Endpoint-identity verification of the shared HTTPS transport, independent of
  chain verification.

  The sibling TLSTest proves that a certificate from an untrusted CA is
  refused. Here the client trusts the issuing CA, so the chain is valid, and
  only the certificate's name differs from the hostname dialed.

  The CA is injected through the transport's `cacerts` setting
  (`config :current, Current.LLMClient.HTTP, cacerts: [...]`). That is
  application configuration read on every request, not request-local state, so
  each test sets it and restores it on exit, and this module is async: false.
  OTP's global public_key CA cache is never modified.

  The positive control shows that the same kind of generated chain succeeds when
  the certificate matches the hostname dialed, so a rejection in the mismatch
  case can only come from the hostname check. Everything runs against a local
  listener: no external network is used.
  """
  use ExUnit.Case, async: false

  alias Current.LLMClient.HTTP

  @moduletag :capture_log
  @timeout_ms 5_000

  # id-ce-subjectAltName
  @san_oid {2, 5, 29, 17}

  setup_all do
    {:ok, match: issue("localhost"), mismatch: issue("wrong.example.test")}
  end

  test "accepts a trusted certificate matching the requested hostname",
       %{match: fixture} do
    url = start_fixture(fixture)

    assert {:ok, "ok"} = request(url)
    assert_received :request_received
  end

  test "rejects a trusted certificate for a different hostname",
       %{mismatch: fixture} do
    url = start_fixture(fixture)

    assert {:error, {:http_error, reason}} = request(url)

    assert hostname_check_failed?(reason),
           "expected hostname_check_failed TLS error, got: #{inspect(reason)}"

    refute_received :request_received
  end

  defp request(url) do
    HTTP.request(:get, {String.to_charlist(url), []}, @timeout_ms)
  end

  # Only the specific hostname-verification failure counts. A generic
  # handshake_failure, unknown_ca, timeout or refused connection must not pass.
  #
  # OTP reports it either as the structured {:bad_cert, :hostname_check_failed}
  # term or as a handshake_failure alert whose description names that reason.
  defp hostname_check_failed?({:bad_cert, :hostname_check_failed}), do: true

  defp hostname_check_failed?({:tls_alert, {:handshake_failure, description}}),
    do: names_hostname_check?(description)

  defp hostname_check_failed?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> hostname_check_failed?()

  defp hostname_check_failed?(list) when is_list(list),
    do: Enum.any?(list, &hostname_check_failed?/1)

  defp hostname_check_failed?(_), do: false

  defp names_hostname_check?(description) do
    description |> IO.chardata_to_string() |> String.contains?("hostname_check_failed")
  rescue
    _ -> false
  end

  # A chain whose leaf certificate carries a single dNSName SAN. The client is
  # given the root as its only trust anchor, so the chain itself is valid.
  defp issue(dns_name) do
    san = {:Extension, @san_oid, false, [dNSName: String.to_charlist(dns_name)]}

    chain = %{
      root: [key: {:rsa, 2048, 65537}],
      intermediates: [],
      peer: [key: {:rsa, 2048, 65537}, extensions: [san]]
    }

    %{server_config: server_config, client_config: client_config} =
      :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    %{
      listen: Keyword.take(server_config, [:cert, :key]),
      cacerts: Keyword.fetch!(client_config, :cacerts)
    }
  end

  # Starts a local TLS listener presenting the fixture's certificate and points
  # the transport's CA override at the fixture's root. The override is restored
  # when the test exits. Returns the URL to request.
  defp start_fixture(fixture) do
    options =
      fixture.listen ++ [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_ip, port}} = :ssl.sockname(listener)
    owner = self()

    start_supervised!({Task, fn -> serve(listener, owner) end})
    on_exit(fn -> :ssl.close(listener) end)

    override_app_env(HTTP, cacerts: fixture.cacerts)

    "https://localhost:#{port}/"
  end

  defp override_app_env(key, value) do
    previous = Application.fetch_env(:current, key)
    Application.put_env(:current, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:current, key, old)
        :error -> Application.delete_env(:current, key)
      end
    end)
  end

  defp serve(listener, owner) do
    body = "ok"

    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, @timeout_ms) do
          {:ok, socket} ->
            case read_request(socket) do
              {:ok, _request} ->
                send(owner, :request_received)

                :ssl.send(
                  socket,
                  "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" <>
                    "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
                )

              {:error, _reason} ->
                :ok
            end

            :ssl.close(socket)

          {:error, _reason} ->
            :ssl.close(socket)
        end

        serve(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  # Reads the request head and, when present, the whole body, so the response is
  # never sent while the client is still writing.
  defp read_request(socket, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        if byte_size(rest) >= content_length(head),
          do: {:ok, acc},
          else: read_more(socket, acc)

      _ ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    case :ssl.recv(socket, 0, @timeout_ms) do
      {:ok, data} -> read_request(socket, acc <> data)
      {:error, _reason} = error -> error
    end
  end

  defp content_length(head) do
    case Regex.run(~r/content-length:\s*(\d+)/i, head) do
      [_, length] -> String.to_integer(length)
      _ -> 0
    end
  end
end
