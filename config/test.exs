import Config

config :current,
  proposal_builder: Current.FakeProposalBuilder,
  llm_client: Current.FakeLLMClient,
  effect_applicator: Current.EffectApplicator,
  data_dir: Path.join(System.tmp_dir!(), "current_test_#{System.os_time(:millisecond)}")
