import Config

config :current,
  proposal_builder: Current.LLMProposalBuilder,
  effect_applicator: Current.EffectApplicator,
  llm_proposal_timeout_ms: 240_000,
  data_dir: "./_data",
  http: [port: 4000, ip: {127, 0, 0, 1}]

# whatever env-independent config you have, then:
import_config "#{config_env()}.exs"
