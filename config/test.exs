import Config

config :current,
  proposal_builder: Current.FakeProposalBuilder,
  effect_applicator: Current.EffectApplicator,
  # runtime.exs never loads operator configuration in tests.
  llm_proposal_timeout_ms: 240_000,
  http: [port: 6000, ip: {127, 0, 0, 1}],
  model_catalog_clients: [
    Current.TestOpenAIModelCatalogClient,
    Current.TestAnthropicModelCatalogClient
  ],
  allowed_commands: [
    "mix",
    "git",
    "rg",
    "echo",
    "cat",
    "sh",
    "false",
    "pwd",
    "bin/hello",
    "this_command_does_not_exist_xyz"
  ],
  # No `input_limits` here on purpose: the suite as a whole runs with the
  # production defaults, so unrelated tests never trip over a tiny limit.
  # The tests that probe limits set their own, for their own duration only
  # (see input_limits_integration_test.exs and mcp_integration_test.exs).
  data_dir: Path.join(System.tmp_dir!(), "current_test_#{System.os_time(:millisecond)}")
