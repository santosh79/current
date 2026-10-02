import Config

config :current,
  proposal_builder: Current.FakeProposalBuilder,
  effect_applicator: Current.EffectApplicator,
  model_catalog_clients: [
    Current.TestOpenAIModelCatalogClient,
    Current.TestAnthropicModelCatalogClient
  ],
  data_dir: Path.join(System.tmp_dir!(), "current_test_#{System.os_time(:millisecond)}")
