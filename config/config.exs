import Config

config :current,
  proposal_builder: Current.LLMProposalBuilder,
  effect_applicator: Current.EffectApplicator,
  llm_proposal_timeout_ms: 240_000,
  # How many times a reviewer may send a workflow's proposal back. Read once,
  # when a workflow is created, and recorded on its WorkflowCreated event.
  max_revisions: 10,
  data_dir: "./_data",
  generate_proposal_files: false,
  http: [port: 4000, ip: {127, 0, 0, 1}],
  # Executables run_command may run. Denied by default; not a sandbox.
  allowed_commands: [],

  # Upper bounds, in bytes, on free-form client input. See Current.InputLimits.
  input_limits: [
    prompt: 32_768,
    feedback: 16_384,
    message: 4_096,
    reviewed_by: 256,
    model: 256,
    dir: 4_096
  ]

# whatever env-independent config you have, then:
import_config "#{config_env()}.exs"
