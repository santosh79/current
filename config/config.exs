import Config

# Code wiring stays in Elixir. Operator settings are loaded from current.yaml
# and CURRENT_* environment variables by config/runtime.exs.
config :current,
  proposal_builder: Current.LLMProposalBuilder,
  effect_applicator: Current.EffectApplicator,
  model_catalog_clients: [
    Current.LLMClient.OpenAI,
    Current.LLMClient.Anthropic
  ]

# whatever env-independent config you have, then:
import_config "#{config_env()}.exs"
