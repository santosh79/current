defmodule Current.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias Current.ConfigLoader

  setup do
    dir =
      Path.join(System.tmp_dir!(), "current_config_loader_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "current.yaml")}
  end

  test "uses built-in defaults when the implicit file is absent", %{path: path} do
    config = ConfigLoader.load(path, %{})

    assert config[:data_dir] == "./_data"
    assert config[:allowed_commands] == []
    assert config[:http] == [ip: {127, 0, 0, 1}, port: 4000]
    assert config[:llm_proposal_timeout_ms] == 240_000
    assert config[:llm_task_timeout_ms] == 600_000
    assert config[:enabled_providers] == ["openai", "anthropic"]
  end

  test "loads command allowlist from YAML and lets environment override it", %{path: path} do
    File.write!(path, "allowed_commands: [mix, git]\n")

    assert ConfigLoader.load(path, %{})[:allowed_commands] == ["mix", "git"]

    config = ConfigLoader.load(path, %{"CURRENT_ALLOWED_COMMANDS" => "rg, mix, rg"})
    assert config[:allowed_commands] == ["rg", "mix"]
  end

  test "an explicit empty allowlist stays empty", %{path: path} do
    File.write!(path, "allowed_commands: []\n")
    assert ConfigLoader.load(path, %{})[:allowed_commands] == []
  end

  test "rejects invalid command allowlists", %{path: path} do
    for yaml <- [
          "allowed_commands: [mix, 12]\n",
          "allowed_commands: mix\n",
          "allowed_commands: ['']\n"
        ] do
      File.write!(path, yaml)

      assert_raise ArgumentError, ~r/configuration file .*: invalid allowed_commands/, fn ->
        ConfigLoader.load(path, %{})
      end
    end

    # Reset to valid YAML before testing the environment override.

    File.write!(path, "allowed_commands: [mix, git]\n")

    assert_raise ArgumentError,
                 ~r/CURRENT_ALLOWED_COMMANDS: invalid allowed_commands/,
                 fn ->
                   ConfigLoader.load(path, %{
                     "CURRENT_ALLOWED_COMMANDS" => "mix, ,git"
                   })
                 end
  end

  test "raises when an explicit file is absent", %{path: path} do
    assert_raise ArgumentError, ~r/configuration file .* does not exist/, fn ->
      ConfigLoader.load(path, %{}, required: true)
    end
  end

  test "YAML overrides defaults and environment overrides YAML", %{path: path} do
    File.write!(path, """
    data_dir: /from/file
    http:
      ip: "0.0.0.0"
      port: 4100
    llm:
      providers: [anthropic]
    workflow:
      max_revisions: 3
    """)

    config =
      ConfigLoader.load(path, %{
        "CURRENT_DATA_DIR" => "/from/env",
        "CURRENT_HTTP_PORT" => "4200",
        "CURRENT_MAX_REVISIONS" => "4"
      })

    assert config[:data_dir] == "/from/env"
    assert config[:http] == [ip: {0, 0, 0, 0}, port: 4200]
    assert config[:enabled_providers] == ["anthropic"]
    assert config[:max_revisions] == 4
  end

  test "empty environment values are unset and do not override YAML", %{path: path} do
    File.write!(path, """
    data_dir: /from/file
    http:
      port: 4100
    llm:
      providers: [anthropic]
    """)

    config =
      ConfigLoader.load(path, %{
        "CURRENT_DATA_DIR" => "",
        "CURRENT_HTTP_PORT" => "",
        "CURRENT_LLM_PROVIDERS" => ""
      })

    assert config[:data_dir] == "/from/file"
    assert config[:http][:port] == 4100
    assert config[:enabled_providers] == ["anthropic"]
  end

  test "rejects unknown YAML keys with their source and path", %{path: path} do
    File.write!(path, "http:\n  prot: 4000\n")

    assert_raise ArgumentError, ~r/configuration file .*invalid http.prot: unknown setting/, fn ->
      ConfigLoader.load(path, %{})
    end
  end

  test "rejects an unknown provider from YAML", %{path: path} do
    File.write!(path, "llm:\n  providers: [opnai]\n")

    assert_raise ArgumentError, ~r/configuration file .*invalid llm.providers/, fn ->
      ConfigLoader.load(path, %{})
    end
  end

  test "rejects an unknown provider from the environment", %{path: path} do
    assert_raise ArgumentError, ~r/CURRENT_LLM_PROVIDERS: invalid llm.providers/, fn ->
      ConfigLoader.load(path, %{"CURRENT_LLM_PROVIDERS" => "openai,opnai"})
    end
  end

  test "rejects an origin with a path from YAML", %{path: path} do
    File.write!(path, "mcp:\n  allowed_origins: [https://agents.example.com/path]\n")

    assert_raise ArgumentError, ~r/configuration file .*invalid mcp.allowed_origins/, fn ->
      ConfigLoader.load(path, %{})
    end
  end

  test "rejects an origin with a path from the environment", %{path: path} do
    assert_raise ArgumentError,
                 ~r/CURRENT_MCP_ALLOWED_ORIGINS: invalid mcp.allowed_origins/,
                 fn ->
                   ConfigLoader.load(path, %{
                     "CURRENT_MCP_ALLOWED_ORIGINS" => "https://agents.example.com/path"
                   })
                 end
  end

  test "accepts provider base URLs and exact origins", %{path: path} do
    File.write!(path, """
    llm:
      openai:
        base_url: https://models.example.com/v1
    mcp:
      allowed_origins: [https://agents.example.com:8443]
    """)

    config = ConfigLoader.load(path, %{})

    assert config[Current.LLMClient.OpenAI] == [base_url: "https://models.example.com/v1"]
    assert config[:mcp][:allowed_origins] == ["https://agents.example.com:8443"]
  end

  test "rejects runner backoff when the base exceeds the maximum", %{path: path} do
    File.write!(path, """
    workflow:
      runner_base_backoff_ms: 30001
      runner_max_backoff_ms: 30000
    """)

    assert_raise ArgumentError,
                 ~r/runner_base_backoff_ms.*less than or equal to workflow.runner_max_backoff_ms/,
                 fn -> ConfigLoader.load(path, %{}) end
  end

  test "invalid scalar types raise ArgumentError rather than FunctionClauseError", %{path: path} do
    File.write!(path, "http:\n  port: []\n")

    assert_raise ArgumentError, ~r/invalid http.port/, fn ->
      ConfigLoader.load(path, %{})
    end
  end
end
