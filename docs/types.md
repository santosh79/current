# Core types

The types the runtime passes around, as they are in the code. Fields marked
`# …` are explained where they matter; the source is the authority.

Two things hold across all of them:

- Ids are strings of the form `sha256:<64 hex digits>`. Events, intents,
  proposals, tasks and workflows get **random** ids (`Current.Id.generate/0`).
  Artifacts get the **hash of their content**. The shared prefix does not
  mean an id is a content hash.
- Contents are never embedded in these structs. A struct holds the id of the
  [artifact](artifact.md) that does.

---

### Id

```elixir
defmodule Current.Id do
  @type t :: String.t()

  def generate()          # "sha256:" <> 32 random bytes, lowercase hex
  def validate(id)        # :ok for "sha256:" <> 64 lowercase hex digits
end
```

### Mode

```elixir
@type t :: :plan | :apply     # default: :apply
```

`:plan` produces and validates a proposal and stops. `:apply` waits for
approval and can then be applied.

### Request

What the user asked for. The project directory is not part of it: it is
execution context, recorded on `TaskCreated`.

```elixir
defmodule Current.Request do
  @enforce_keys [:input, :context, :model]
  defstruct [:input, :context, :model, mode: :apply, timeout_ms: nil]

  @type t :: %__MODULE__{
          input: String.t() | map(),
          context: map(),
          model: String.t(),            # "provider:model_id", from the model catalog
          mode: Current.Mode.t(),
          timeout_ms: pos_integer() | nil   # nil = the runtime's default
        }
end
```

### Task

```elixir
defmodule Current.Task do
  @enforce_keys [:id, :input, :context, :mode, :model, :submitted_at]
  defstruct [:id, :input, :context, :mode, :submitted_at, :project_dir, :model, :timeout_ms]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t(),
          project_dir: Path.t() | nil,      # canonical real path; nil only for very old records
          model: String.t(),
          timeout_ms: pos_integer() | nil,
          submitted_at: DateTime.t()
        }
end
```

### Workflow

A workflow is derived state: `WorkflowReducer` folds the workflow's events
into it. It is never written directly.

```elixir
defmodule Current.Workflow do
  @enforce_keys [:id, :task_id, :status, :created_at]
  defstruct [
    :id, :task_id, :status, :proposal, :result, :events, :mode,
    :started_at, :created_at, :completed_at, :updated_at, :error
  ]

  @type status ::
          :created
          | :planning
          | :validating
          | :waiting_for_approval
          | :validation_failed
          | :approved
          | :applying
          | :assembling_result
          | :completed
          | :planned
          | :invalid_mode
          | :rejected
          | :failed
          | :proposal_production_failed
          | :abandoned

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          status: status(),
          proposal: Current.Proposal.t() | nil,
          result: Current.WorkflowResult.t() | nil,
          events: [Current.Event.t()],
          mode: Current.Mode.t(),
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          error: String.t() | nil
        }
end
```

Terminal statuses are `:completed`, `:planned`, `:rejected`, `:failed` and
`:abandoned`. `:validation_failed`, `:invalid_mode` and
`:proposal_production_failed` are not terminal: each is followed by a
`WorkflowFailed` event that moves the workflow to `:failed`.

### Proposal

```elixir
defmodule Current.Proposal do
  @enforce_keys [:id, :workflow_id, :intents]
  defstruct [:id, :workflow_id, :intents, :justification, :claims, :dependencies,
             observations: []]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intents: [Current.Intent.t()],
          justification: String.t() | nil,
          claims: [String.t()] | nil,
          dependencies: [String.t()] | nil,
          observations: [Current.Observation.t()]   # what the agent looked at first
        }
end
```

`justification`, `claims` and `dependencies` belong to the proposal, not to
individual intents.

### Intent

There is no generic `%Intent{type:, payload:}`. Each intent type is its own
struct, so the compiler knows its fields. Every one carries `id` and
`proposal_id`. By the time a proposal is recorded, every path is absolute.

```elixir
Current.Intent.ReadFile    # path
Current.Intent.Glob        # pattern, base_dir (default ".")
Current.Intent.Grep        # pattern, paths
Current.Intent.WriteFile   # path, contents_artifact_id
Current.Intent.EditFile    # path, old_artifact_id, new_artifact_id, replace_all (default false)
Current.Intent.DeleteFile  # path
Current.Intent.RunCommand  # cmd, args (default [])
Current.Intent.Claim       # statement, evidence, expected
Current.Intent.Report      # summary
```

```elixir
@type t ::
        Current.Intent.EditFile.t()
        | Current.Intent.WriteFile.t()
        | Current.Intent.DeleteFile.t()
        | Current.Intent.RunCommand.t()
        | Current.Intent.ReadFile.t()
        | Current.Intent.Glob.t()
        | Current.Intent.Grep.t()
        | Current.Intent.Claim.t()
        | Current.Intent.Report.t()
```

`Current.Intent.modules/0` is the closed set; `Current.Intent.valid?/1` tests
membership. `old_artifact_id` and `new_artifact_id` point at the exact
`old_string` and `new_string` bytes. A claim's `evidence` is
`%{source_intent_id, condition, value}`, where `condition` is
`:match_count_greater_than`, `:match_count_equals` or `:exit_code_equals`.

### Observation

One thing the agent asked to see before proposing, and what came of it. It
wraps a single read-only intent and, like an intent, never holds contents.

```elixir
defmodule Current.Observation do
  @enforce_keys [:id, :intent]
  defstruct [:id, :intent, :reason, :round, :reply_artifact_id,
             :artifact_id, :error, status: :requested]

  @type status :: :requested | :shown | :refused

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          intent: Intent.ReadFile.t() | Intent.Glob.t() | Intent.Grep.t(),
          reason: String.t() | nil,
          round: pos_integer() | nil,
          reply_artifact_id: Current.Id.t() | nil,  # the model reply that asked for it
          status: status(),
          artifact_id: Current.Id.t() | nil,        # what the agent was shown (:shown)
          error: String.t() | nil                   # why it was shown nothing (:refused)
        }
end
```

### EffectResult

What applying an intent produced. One struct per intent type; large
content is held as an artifact id.

```elixir
Current.EffectResult.ReadFile    # path, contents_artifact_id, bytes
Current.EffectResult.Glob        # matches_artifact_id, match_count
Current.EffectResult.Grep        # matches_artifact_id, match_count, searched_artifact_ids
Current.EffectResult.WriteFile   # path
Current.EffectResult.EditFile    # path, before_artifact_id, after_artifact_id, replacements
Current.EffectResult.DeleteFile  # path, before_artifact_id
Current.EffectResult.Command     # exit_code, stdout_artifact_id, stderr_artifact_id,
                                 #   stdout_bytes, stderr_bytes
Current.EffectResult.Claim       # verified, statement, reason, evidence
Current.EffectResult.Report      # generated
```

`Current.EffectApplicator.result()` is the union of these.

### WorkflowResult

```elixir
defmodule Current.WorkflowResult do
  @enforce_keys [:id, :workflow_id, :type, :intent_results, :created_at]
  defstruct [:id, :workflow_id, :type, :intent_results, :summary, :metadata, :created_at]

  @type type :: :result_bundle | :report | :manifest | :patch_set | :verification_output

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          type: type(),
          intent_results: [{Current.Intent.t(), Current.EffectApplicator.result()}],
          summary: String.t() | nil,
          metadata: map() | nil,
          created_at: DateTime.t()
        }
end
```

### Event

There is no generic `%Event{type:, data:}`. Each event type is its own
struct. `Current.Event.t()` is the union of them, and
`Current.Event.modules/0` is the closed set. See [event.md](event.md) for
each one's fields and for how versions and upcasts work.

```elixir
TaskCreated · WorkflowCreated · ProposalProductionStarted · ModeInvalid ·
ProposalProduced · ProposalProductionFailed · ProposalValidated ·
ProposalValidationFailed · ProposalApproved · ProposalRejected ·
EffectApplicationStarted · EffectApplied · EffectFailed ·
EffectApplicationComplete · WorkflowResultAssembled · WorkflowCompleted ·
WorkflowFailed · WorkflowAbandoned
```

### Errors

```elixir
defmodule Current.Error.ValidationError do
  @enforce_keys [:intent_id, :reason]
  defstruct [:intent_id, :reason, details: %{}]
end

defmodule Current.Error.ProposalProductionError do
  @enforce_keys [:stage, :reason]
  defstruct [:stage, :reason, :raw_output_blob_id]

  @type stage :: :project_context | :connection | :timeout | :decode
               | :context_budget | :internal | nil
end
```

### Commit

Events are appended to the write-ahead log in commits.

```elixir
defmodule Current.Consensus.Commit do
  @enforce_keys [:index, :events, :previous_hash]
  defstruct [:index, :events, :previous_hash]

  # hash/1 = SHA-256 of :erlang.term_to_binary(commit)
end
```

The [commit log notes](commit_log_design_notes.md) explain the chain, the
segments and what replay requires.

