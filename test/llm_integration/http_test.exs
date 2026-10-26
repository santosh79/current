defmodule Current.LLMIntegration.HTTPTest do
  use ExUnit.Case, async: false

  alias Current.LLMClient.{Anthropic, HTTP, OpenAI}

  setup do
    previous =
      for provider <- [OpenAI, Anthropic],
          do: {provider, Application.fetch_env(:current, provider)}

    for provider <- [OpenAI, Anthropic], do: Application.delete_env(:current, provider)

    on_exit(fn ->
      for {provider, value} <- previous do
        case value do
          {:ok, config} -> Application.put_env(:current, provider, config)
          :error -> Application.delete_env(:current, provider)
        end
      end
    end)

    :ok
  end

  test "TLS policy explicitly verifies peers and HTTPS hostnames" do
    certificates = [<<1, 2, 3>>]
    assert {:ok, options} = HTTP.ssl_opts(fn -> certificates end)
    assert options[:verify] == :verify_peer
    assert options[:cacerts] == certificates
    assert options[:versions] == [:"tlsv1.2", :"tlsv1.3"]
    assert is_function(options[:customize_hostname_check][:match_fun], 2)
  end

  test "missing or empty CA stores return an error instead of raising" do
    assert HTTP.ssl_opts(fn -> :erlang.error(:enoent) end) == {:error, :no_ca_certificates}
    assert HTTP.ssl_opts(fn -> raise "CA store unavailable" end) == {:error, :no_ca_certificates}
    assert HTTP.ssl_opts(fn -> [] end) == {:error, :no_ca_certificates}
  end

  test "default and overridden base URLs retain their API path" do
    assert HTTP.endpoint(OpenAI, "https://api.openai.com/v1", "/responses") ==
             {:ok, ~c"https://api.openai.com/v1/responses"}

    Application.put_env(:current, OpenAI, base_url: "https://localhost:1234/v1/")

    assert HTTP.endpoint(OpenAI, "https://api.openai.com/v1", "/models") ==
             {:ok, ~c"https://localhost:1234/v1/models"}

    assert HTTP.endpoint(Anthropic, "https://api.anthropic.com/v1", "/messages") ==
             {:ok, ~c"https://api.anthropic.com/v1/messages"}
  end

  test "overrides cannot disable HTTPS or embed credentials, queries or fragments" do
    for base_url <- [
          nil,
          "http://localhost:1234/v1",
          "ftp://localhost/v1",
          "https:///v1",
          "https://user:password@localhost/v1",
          "https://localhost/v1?query=1",
          "https://localhost/v1#fragment"
        ] do
      Application.put_env(:current, OpenAI, base_url: base_url)

      assert HTTP.endpoint(OpenAI, "https://api.openai.com/v1", "/models") ==
               {:error, :invalid_provider_base_url}
    end
  end
end
