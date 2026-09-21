import Config

config :current,
  proposal_builder: Current.LLMProposalBuilder,
  llm_client: Current.LLMClient.OpenAI,
  effect_applicator: Current.EffectApplicator

# whatever env-independent config you have, then:
import_config "#{config_env()}.exs"
