defmodule Current.LLMIntegration.TLSTest do
  use ExUnit.Case, async: false

  alias Current.LLMClient.{Anthropic, OpenAI}

  @moduletag :capture_log
  @timeout_ms 5_000

  setup_all do
    # A fresh private CA is never in the OS trust store. Generate certificates
    # at runtime so the fixture cannot expire and no private keys are committed.
    chain = %{
      root: [key: {:rsa, 2048, 65537}],
      intermediates: [],
      peer: [key: {:rsa, 2048, 65537}]
    }

    %{server_config: server_config} =
      :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    {:ok, server_config: server_config}
  end

  setup %{server_config: server_config} do
    options =
      Keyword.take(server_config, [:cert, :key]) ++
        [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_ip, port}} = :ssl.sockname(listener)
    owner = self()

    start_supervised!({Task, fn -> serve(listener, owner) end})

    previous =
      for {provider, key} <- [{OpenAI, "OPENAI_API_KEY"}, {Anthropic, "ANTHROPIC_API_KEY"}] do
        saved = {provider, Application.fetch_env(:current, provider), key, System.get_env(key)}
        Application.put_env(:current, provider, base_url: "https://127.0.0.1:#{port}/v1")
        System.put_env(key, "local-test-key")
        saved
      end

    on_exit(fn ->
      :ssl.close(listener)

      for {provider, config, key, value} <- previous do
        case config do
          {:ok, config} -> Application.put_env(:current, provider, config)
          :error -> Application.delete_env(:current, provider)
        end

        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end
    end)

    {:ok, port: port}
  end

  test "fixture accepts TLS and serves HTTP when verification is deliberately disabled", %{
    port: port
  } do
    # Positive control only; production clients never expose a verify_none option.
    assert {:ok, socket} =
             :ssl.connect(
               {127, 0, 0, 1},
               port,
               [verify: :verify_none, active: false, mode: :binary],
               @timeout_ms
             )

    try do
      assert :ok = :ssl.send(socket, "GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert {:ok, response} = :ssl.recv(socket, 0, @timeout_ms)
      assert response =~ "HTTP/1.1 200 OK"
      assert_receive :request_received
    after
      :ssl.close(socket)
    end
  end

  for provider <- [OpenAI, Anthropic], operation <- [:complete, :list_models] do
    test "#{inspect(provider)} #{operation} refuses a certificate from an untrusted CA" do
      provider = unquote(provider)

      result =
        case unquote(operation) do
          :complete -> provider.complete([], @timeout_ms, "test-model")
          :list_models -> provider.list_models(@timeout_ms)
        end

      assert {:error, {:http_error, reason}} = result

      assert unknown_ca_alert?(reason),
             "expected an unknown_ca TLS alert, got: #{inspect(reason)}"

      refute_received :request_received
    end
  end

  # Inspect the structured transport error, not OTP-version-specific wording.
  # A timeout, refused connection or unrelated HTTP error must not pass.
  defp unknown_ca_alert?({:tls_alert, {:unknown_ca, _description}}), do: true

  defp unknown_ca_alert?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> unknown_ca_alert?()

  defp unknown_ca_alert?(list) when is_list(list), do: Enum.any?(list, &unknown_ca_alert?/1)
  defp unknown_ca_alert?(_), do: false

  defp serve(listener, owner) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, @timeout_ms) do
          {:ok, socket} ->
            case :ssl.recv(socket, 0, @timeout_ms) do
              {:ok, _request} ->
                send(owner, :request_received)

                :ssl.send(
                  socket,
                  "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
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
end
