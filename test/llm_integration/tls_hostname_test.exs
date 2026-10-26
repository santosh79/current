defmodule Current.LLMIntegration.TLSHostnameTest do
  @moduledoc """
  Endpoint-identity verification, independent of chain verification.

  The sibling TLSTest proves that a certificate from an untrusted CA is
  refused. Here the client trusts the issuing CA, so the chain is valid, and
  only the certificate's name differs from the hostname dialed.

  The CA is injected through the shared transport's `cacerts` setting
  (`config :current, Current.LLMClient.HTTP, cacerts: [...]`). That is
  application configuration read on every request, not request-local state, so
  each test sets it and restores it on exit, and this module is async: false.
  OTP's global public_key CA cache is never modified.

  Positive controls show that the same kind of generated chain succeeds when
  the certificate matches the hostname dialed, so a rejection in the mismatch
  case can only come from the hostname check. Everything runs against a local
  listener: no external network is used.
  """
  use ExUnit.Case, async: false

  alias Current.LLMClient.{Anthropic, HTTP, OpenAI}

  @moduletag :capture_log
  @timeout_ms 5_000

  # id-ce-subjectAltName
  @san_oid {2, 5, 29, 17}

  @providers [{OpenAI, "OPENAI_API_KEY"}, {Anthropic, "ANTHROPIC_API_KEY"}]

  setup_all do
    {:ok, match: issue("localhost"), mismatch: issue("wrong.example.test")}
  end

  for provider <- [OpenAI, Anthropic], operation <- [:complete, :list_models] do
    test "#{inspect(provider)} #{operation} succeeds when the certificate matches the hostname",
         %{match: fixture} do
      provider = unquote(provider)
      operation = unquote(operation)
      start_fixture(fixture, body_for(provider, operation))

      assert {:ok, value} = call(provider, operation)

      case operation do
        :complete -> assert value == %{text: "hello", usage: nil}
        :list_models -> assert value == ["m1"]
      end

      assert_received :request_received
    end

    test "#{inspect(provider)} #{operation} refuses a trusted chain issued for another hostname",
         %{mismatch: fixture} do
      provider = unquote(provider)
      operation = unquote(operation)
      start_fixture(fixture, body_for(provider, operation))

      assert {:error, {:http_error, reason}} = call(provider, operation)

      assert hostname_check_failed?(reason),
             "expected a hostname_check_failed TLS error, got: #{inspect(reason)}"

      refute_received :request_received
    end
  end

  defp call(provider, :complete), do: provider.complete([], @timeout_ms, "test-model")
  defp call(provider, :list_models), do: provider.list_models(@timeout_ms)

  defp body_for(_provider, :list_models), do: JSON.encode!(%{"data" => [%{"id" => "m1"}]})

  defp body_for(OpenAI, :complete) do
    JSON.encode!(%{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "hello"}]
        }
      ]
    })
  end

  defp body_for(Anthropic, :complete) do
    JSON.encode!(%{"content" => [%{"type" => "text", "text" => "hello"}]})
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
  # both providers, the transport's CA override and the API keys at it. All of it
  # is restored when the test exits.
  defp start_fixture(fixture, body) do
    options =
      fixture.listen ++ [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_ip, port}} = :ssl.sockname(listener)
    owner = self()

    start_supervised!({Task, fn -> serve(listener, owner, body) end})
    on_exit(fn -> :ssl.close(listener) end)

    for {provider, key} <- @providers do
      override_app_env(provider, base_url: "https://localhost:#{port}/v1")
      override_system_env(key, "local-test-key")
    end

    override_app_env(HTTP, cacerts: fixture.cacerts)
    :ok
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

  defp override_system_env(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if previous == nil, do: System.delete_env(key), else: System.put_env(key, previous)
    end)
  end

  defp serve(listener, owner, body) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, @timeout_ms) do
          {:ok, socket} ->
            case read_request(socket) do
              {:ok, _request} ->
                send(owner, :request_received)

                :ssl.send(
                  socket,
                  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
                    "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
                )

              {:error, _reason} ->
                :ok
            end

            :ssl.close(socket)

          {:error, _reason} ->
            :ssl.close(socket)
        end

        serve(listener, owner, body)

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
