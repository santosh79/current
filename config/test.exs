import Config

config :current,
  proposal_builder: Current.FakeProposalBuilder,
  llm_client: Current.FakeLLMClient,
  effect_applicator: Current.EffectApplicator,
  consensus_log_path:
    Path.join([System.tmp_dir!(), "current_test_#{System.os_time(:millisecond)}", "commit_log"])
