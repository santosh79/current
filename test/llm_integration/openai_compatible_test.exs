defmodule Current.LLMIntegration.OpenAICompatibleTest do
  use ExUnit.Case, async: false

  alias Current.LLMClient.{HTTP, OpenAI, OpenAICompatible}

  @suffixes ~w(BASE_URL API_KEY MAX_TOKENS RESPONSE_FORMAT JSON_SCHEMA_STRICT EXTRA_FIELDS
               ALLOW_HTTP_HOSTNAMES PROPOSAL_TIMEOUT_MS TASK_TIMEOUT_MS)

  setup do
    saved = for suffix <- @suffixes, do: {env_key(suffix), System.get_env(env_key(suffix))}
    config = Application.fetch_env(:current, OpenAICompatible)
    for {key, _} <- saved, do: System.delete_env(key)
    Application.delete_env(:current, OpenAICompatible)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end

      case config do
        {:ok, value} -> Application.put_env(:current, OpenAICompatible, value)
        :error -> Application.delete_env(:current, OpenAICompatible)
      end
    end)

    # Unique model name keeps tests independent.
    {:ok, model: "model-#{System.unique_integer([:positive])}"}
  end

  test "provider is disabled without a base URL" do
    assert OpenAICompatible.provider() == "local"
    assert {:error, :missing_local_llm_base_url} = OpenAICompatible.list_models(100)
    assert {:error, :missing_local_llm_base_url} = OpenAICompatible.complete([], 100, "model")

    System.put_env("CURRENT_LOCAL_LLM_BASE_URL", "")
    assert {:error, :missing_local_llm_base_url} = OpenAICompatible.list_models(100)
  end

  test "lists models and sends Chat Completions with optional auth, schema and usage" do
    fixture([
      {200, JSON.encode!(%{"data" => [%{"id" => "coder:latest"}, %{"id" => 1}]})},
      {200, completion("<think>private reasoning</think>\n{\"intents\":[]}")}
    ])

    assert {:ok, ["coder:latest"]} = OpenAICompatible.list_models(2_000)
    assert_receive {:request, head, ""}
    assert head =~ "GET /v1/models "
    refute String.downcase(head) =~ "authorization:"

    System.put_env("CURRENT_LOCAL_LLM_API_KEY", "test-secret")
    messages = [%{role: :system, content: "JSON only"}, %{role: :user, content: "fix it"}]

    assert {:ok,
            %{
              text: "{\"intents\":[]}",
              usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
            }} = OpenAICompatible.complete(messages, 2_000, "coder:latest")

    assert_receive {:request, head, raw}
    assert head =~ "POST /v1/chat/completions "
    assert String.downcase(head) =~ "authorization: bearer test-secret"
    body = JSON.decode!(raw)
    assert body["model"] == "coder:latest"

    assert body["messages"] == [
             %{"role" => "system", "content" => "JSON only"},
             %{"role" => "user", "content" => "fix it"}
           ]

    assert body["stream"] == false
    assert body["max_tokens"] == 16_000
    assert body["response_format"]["json_schema"]["strict"] == false

    assert body["response_format"]["json_schema"]["schema"] ==
             JSON.decode!(Current.ProposalWireSchema.raw())
  end

  test "auto tries progressively simpler response formats on explicit format errors", %{
    model: model
  } do
    fixture([
      {400, "unsupported response_format json_schema"},
      {200, completion("{}")},
      {400, "unsupported response_format json_schema"},
      {200, completion("{}")}
    ])

    assert {:ok, _} = OpenAICompatible.complete([], 2_000, model)
    assert format_request() == "json_schema"
    assert format_request() == "json_object"

    # No cache or extra background process: the next call checks again.
    assert {:ok, _} = OpenAICompatible.complete([], 2_000, model)
    assert format_request() == "json_schema"
    assert format_request() == "json_object"
  end

  test "auto can fall back to omitted response_format", %{model: model} do
    fixture([
      {400, "unsupported json_schema"},
      {422, "unsupported response_format"},
      {200, completion("{}")}
    ])

    assert {:ok, _} = OpenAICompatible.complete([], 2_000, model)
    assert format_request() == "json_schema"
    assert format_request() == "json_object"
    assert format_request() == nil
  end

  test "context errors, authentication failures and unrelated errors do not trigger fallback",
       %{model: model} do
    for response <- [
          {400, "context_length exceeded while using response_format"},
          {400, "bad model"},
          {401, "response_format unauthorized"},
          {500, "json_schema failure"}
        ] do
      fixture([response])
      assert {:error, {:http_error, _, _}} = OpenAICompatible.complete([], 2_000, model)
      assert_receive {:request, _, _}
      refute_receive {:unexpected_request, _, _}, 50
    end
  end

  test "none strips an extra response_format, while other extras and configured limits survive",
       %{model: model} do
    fixture([{200, completion("{}")}, {200, completion("{}")}])
    System.put_env("CURRENT_LOCAL_LLM_RESPONSE_FORMAT", "none")
    System.put_env("CURRENT_LOCAL_LLM_MAX_TOKENS", "24000")

    System.put_env(
      "CURRENT_LOCAL_LLM_EXTRA_FIELDS",
      ~s({"response_format":{"type":"json_schema"},"stream":true,"model":"wrong","options":{"num_ctx":32768}})
    )

    assert {:ok, _} = OpenAICompatible.complete([], 2_000, model)
    assert_receive {:request, _, raw}
    body = JSON.decode!(raw)
    refute Map.has_key?(body, "response_format")
    assert body["max_tokens"] == 24_000
    assert body["model"] == model
    assert body["stream"] == false
    assert body["options"] == %{"num_ctx" => 32_768}

    System.put_env("CURRENT_LOCAL_LLM_RESPONSE_FORMAT", "json_schema")
    System.put_env("CURRENT_LOCAL_LLM_JSON_SCHEMA_STRICT", "true")
    assert {:ok, _} = OpenAICompatible.complete([], 2_000, model)
    assert_receive {:request, _, raw}
    assert JSON.decode!(raw)["response_format"]["json_schema"]["strict"] == true
  end

  test "explicit schema mode does not fall back", %{model: model} do
    fixture([{400, "unsupported json_schema"}])
    System.put_env("CURRENT_LOCAL_LLM_RESPONSE_FORMAT", "json_schema")
    assert {:error, {:http_error, 400, _}} = OpenAICompatible.complete([], 1_000, model)
    assert_receive {:request, _, _}
    refute_receive {:unexpected_request, _, _}, 50
  end

  test "a slow attempt times out without negotiating or resetting its deadline", %{model: model} do
    fixture([{200, completion("{}"), 500}])
    start = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = OpenAICompatible.complete([], 150, model)
    assert System.monotonic_time(:millisecond) - start < 1_000
    assert_receive {:request, _, _}
    refute_receive {:unexpected_request, _, _}, 50
  end

  test "each attempt may use the whole remaining deadline, not a share held for fallbacks",
       %{model: model} do
    # Nothing is cached for this model, so `auto` has three modes in reserve.
    # A model that takes 400ms of a 1s budget must not be cut off at a third.
    fixture([{200, completion("{}"), 400}])
    assert {:ok, _} = OpenAICompatible.complete([], 1_000, model)
    assert format_request() == "json_schema"

    # The same holds for the attempt after a rejected format.
    fixture([{400, "unsupported response_format"}, {200, completion("{}"), 400}])
    assert {:ok, _} = OpenAICompatible.complete([], 1_000, model <> "-b")
    assert format_request() == "json_schema"
    assert format_request() == "json_object"
  end

  test "empty settings count as unset, malformed ones are rejected before a request is sent",
       %{model: model} do
    fixture([{200, completion("{}")}])

    for suffix <- ~w(MAX_TOKENS RESPONSE_FORMAT JSON_SCHEMA_STRICT EXTRA_FIELDS) do
      System.put_env(env_key(suffix), "")
    end

    assert {:ok, _} = OpenAICompatible.complete([], 1_000, model)
    assert_receive {:request, _, raw}
    assert JSON.decode!(raw)["max_tokens"] == 16_000

    for {suffix, value} <- [
          {"MAX_TOKENS", "0"},
          {"EXTRA_FIELDS", "[]"},
          {"RESPONSE_FORMAT", "typo"},
          {"JSON_SCHEMA_STRICT", "yes"},
          {"PROPOSAL_TIMEOUT_MS", "soon"}
        ] do
      System.put_env(env_key(suffix), value)

      assert {:error, {:invalid_local_llm_setting, ^suffix}} =
               OpenAICompatible.complete([], 1_000, model)

      System.delete_env(env_key(suffix))
    end

    refute_receive {:request, _, _}, 50
  end

  test "local timeouts validate explicitly configured values" do
    assert {:ok, {240_000, 600_000}} = OpenAICompatible.timeouts(240_000, 600_000)

    System.put_env("CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS", "900000")
    System.put_env("CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS", "1800000")
    assert {:ok, {900_000, 1_800_000}} = OpenAICompatible.timeouts(240_000, 600_000)

    System.put_env("CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS", "0")

    assert {:error, {:invalid_local_llm_setting, "PROPOSAL_TIMEOUT_MS"}} =
             OpenAICompatible.timeouts(240_000, 600_000)
  end

  test "decoding rejects truncation before trying to use partial JSON" do
    raw =
      JSON.encode!(%{
        "choices" => [%{"finish_reason" => "length", "message" => %{"content" => "{"}}],
        "usage" => %{"completion_tokens" => 42}
      })

    assert {:error, {:truncated, :length, 42}} = OpenAICompatible.decode_response(raw)

    no_usage =
      JSON.encode!(%{
        "choices" => [%{"finish_reason" => "length", "message" => %{"content" => "{"}}]
      })

    assert {:error, {:truncated, :length, 1234}} =
             OpenAICompatible.decode_response(no_usage, 1234)
  end

  test "decoding reports what is missing, not a crash" do
    assert {:error, :no_output_text} = OpenAICompatible.decode_response("{}")
    assert {:error, :no_output_text} = OpenAICompatible.decode_response("[]")
    assert {:error, {:decode_failed, _}} = OpenAICompatible.decode_response("bad json")

    # A server that puts the reasoning elsewhere can answer with no content.
    null_content =
      JSON.encode!(%{
        "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => nil}}]
      })

    assert {:error, :no_output_text} = OpenAICompatible.decode_response(null_content)
    assert {:error, :no_output_text} = OpenAICompatible.decode_response(completion("   "))
  end

  test "decoding removes leading reasoning blocks and nothing else" do
    assert {:error, :no_output_text} =
             OpenAICompatible.decode_response(completion("<think>unfinished"))

    two = "<think>a</think>\n<think>b</think>\n{}"
    assert {:ok, %{text: "{}"}} = OpenAICompatible.decode_response(completion(two))

    literal = ~s({"text":"<think>keep this</think>"})
    assert {:ok, %{text: ^literal}} = OpenAICompatible.decode_response(completion(literal))
  end

  test "decoding keeps valid text when usage is absent, partial or malformed" do
    body = fn usage ->
      JSON.encode!(%{
        "choices" => [%{"message" => %{"content" => "ok"}}],
        "usage" => usage
      })
    end

    assert {:ok, %{usage: nil}} =
             OpenAICompatible.decode_response(body.(%{"prompt_tokens" => "bad"}))

    assert {:ok, %{usage: %{input_tokens: 3, output_tokens: 4, total_tokens: 7}}} =
             OpenAICompatible.decode_response(
               body.(%{"prompt_tokens" => 3, "completion_tokens" => 4})
             )

    assert {:ok, %{text: "ok", usage: nil}} =
             OpenAICompatible.decode_response(
               JSON.encode!(%{"choices" => [%{"message" => %{"content" => "ok"}}]})
             )
  end

  test "reaches a server listening on IPv6 loopback" do
    # httpc connects over IPv4 unless asked otherwise. Needs IPv6 loopback on the
    # machine running the tests (most have it); without it there is nothing to reach.
    case :gen_tcp.listen(0, [:binary, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
      {:ok, probe} ->
        :gen_tcp.close(probe)
        fixture([{200, JSON.encode!(%{"data" => [%{"id" => "v6-model"}]})}], :v6)
        assert {:ok, ["v6-model"]} = OpenAICompatible.list_models(2_000)
        assert_receive {:request, "GET /v1/models " <> _, ""}

      {:error, _no_ipv6_loopback} ->
        :ok
    end
  end

  test "local HTTP is restricted without weakening hosted provider policy" do
    for base <- [
          "http://127.0.0.1:1234/v1",
          "http://10.1.2.3/v1",
          "http://172.16.0.1/v1",
          "http://192.168.1.1/v1",
          "http://[::1]/v1",
          "http://[fd00::1]/v1",
          "http://[::ffff:192.168.1.5]/v1"
        ] do
      assert {:ok, _} = HTTP.endpoint(OpenAICompatible, base, "/models"), base
    end

    assert {:ok, ~c"http://127.0.0.1:1234/v1/models"} =
             HTTP.endpoint(OpenAICompatible, "http://localhost:1234/v1", "/models")

    assert {:ok, ~c"http://[::1]:1234/v1/models"} =
             HTTP.endpoint(OpenAICompatible, "http://[::1]:1234/v1/", "/models")

    for base <- [
          "http://8.8.8.8/v1",
          "http://172.32.0.1/v1",
          "http://0.0.0.0/v1",
          "http://[2001:4860::1]/v1",
          "http://[::ffff:8.8.8.8]/v1",
          "http://host.docker.internal/v1"
        ] do
      assert {:error, {:insecure_local_llm_url, _}} =
               HTTP.endpoint(OpenAICompatible, base, "/models"),
             base
    end

    System.put_env("CURRENT_LOCAL_LLM_ALLOW_HTTP_HOSTNAMES", "true")
    assert {:ok, _} = HTTP.endpoint(OpenAICompatible, "http://host.docker.internal/v1", "/models")

    # The hostname opt-in is for hostnames only: public IP literals stay refused.
    assert {:error, {:insecure_local_llm_url, _}} =
             HTTP.endpoint(OpenAICompatible, "http://8.8.8.8/v1", "/models")

    assert {:error, :invalid_provider_base_url} =
             HTTP.endpoint(OpenAI, "http://127.0.0.1/v1", "/models")

    for base <- [
          "https://user:pass@localhost/v1",
          "https://localhost/v1?q=1",
          "https://localhost/v1#x",
          "http://user:pass@127.0.0.1/v1",
          "ftp://localhost/v1"
        ] do
      assert {:error, :invalid_provider_base_url} =
               HTTP.endpoint(OpenAICompatible, base, "/models"),
             base
    end
  end

  test "direct shared HTTP requests cannot bypass the hosted HTTPS policy" do
    assert {:error, :invalid_provider_base_url} =
             HTTP.request(:get, {~c"http://127.0.0.1:1234/v1/models", []}, 100)
  end

  test "server error bodies are not propagated verbatim" do
    fixture([{500, "confidential prompt or token: abc123"}])

    assert {:error, {:http_error, 500, ""}} =
             OpenAICompatible.complete([], 2_000, "test-model")

    assert_receive {:request, _, _}
  end

  ## --- Fixtures ----------------------------------------------------------------

  defp env_key(suffix), do: "CURRENT_LOCAL_LLM_" <> suffix

  defp completion(text) do
    JSON.encode!(%{
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => text}}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12}
    })
  end

  defp format_request do
    assert_receive {:request, _, raw}
    get_in(JSON.decode!(raw), ["response_format", "type"])
  end

  # A loopback HTTP server that answers its requests in order and points the
  # provider at itself. Each response is `{status, body}` or `{status, body,
  # delay_ms}`. Every request is reported as `{:request, head, body}`; one
  # beyond the script is answered with a 599 and reported as
  # `{:unexpected_request, head, body}`, so a test can prove nothing else was sent.
  defp fixture(responses, family \\ :v4) do
    parent = self()

    {ip, host} =
      if family == :v6,
        do: {{0, 0, 0, 0, 0, 0, 0, 1}, "[::1]"},
        else: {{127, 0, 0, 1}, "127.0.0.1"}

    server =
      spawn(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: ip, reuseaddr: true])

        {:ok, port} = :inet.port(listener)
        send(parent, {:fixture_port, self(), port})
        serve(listener, parent, responses)
      end)

    port =
      receive do
        {:fixture_port, ^server, port} -> port
      after
        2_000 -> flunk("the fixture server did not start")
      end

    on_exit(fn -> Process.exit(server, :kill) end)
    System.put_env("CURRENT_LOCAL_LLM_BASE_URL", "http://#{host}:#{port}/v1")
    port
  end

  defp serve(listener, owner, responses) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {head, body} = read_request(socket)

    {status, payload, delay, rest} =
      case responses do
        [{status, payload} | rest] ->
          send(owner, {:request, head, body})
          {status, payload, 0, rest}

        [{status, payload, delay} | rest] ->
          send(owner, {:request, head, body})
          {status, payload, delay, rest}

        [] ->
          send(owner, {:unexpected_request, head, body})
          {599, "unexpected request", 0, []}
      end

    Process.sleep(delay)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Fixture\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n",
      payload
    ])

    :gen_tcp.close(socket)
    serve(listener, owner, rest)
  end

  defp read_request(socket, received \\ <<>>) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    received = received <> data

    case :binary.split(received, "\r\n\r\n") do
      [head, rest] -> {head, read_body(socket, rest, content_length(head))}
      [_incomplete] -> read_request(socket, received)
    end
  end

  defp content_length(head) do
    case Regex.run(~r/content-length:\s*(\d+)/i, head) do
      [_, length] -> String.to_integer(length)
      nil -> 0
    end
  end

  defp read_body(_socket, rest, length) when byte_size(rest) >= length,
    do: binary_part(rest, 0, length)

  defp read_body(socket, rest, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, rest <> more, length)
  end
end
