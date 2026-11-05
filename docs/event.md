# What is an Event?

## Definition

An **Event** is:

> **An immutable, typed record of something that has already happened in the runtime.**

If an intent is a proposal, an event is a fact.

An event does not describe what *should* happen. It records what *did* happen.

---

## Invariants

The following must always hold for any valid event:

1. **Immutable**: An event is never modified after it is recorded. Corrections are expressed as new events, not edits to old ones.

2. **Serializable**: An event is plain data (an Erlang term). It contains no executable code.

3. **Typed**: Every event belongs to a predefined, closed set of event types. Free-form event types are not allowed.

4. **Past-tense only**: An event describes something that has already occurred. It never describes a proposed or hypothetical action.

5. **Context-bound**: Every event belongs to a workflow (`workflow_id`). The one exception is `TaskCreated`, which comes first and belongs to a task (`task_id`).

6. **Append-only**: Events are only added to the log. Existing events are never deleted or rewritten.

7. **Replayable**: Events contain enough information to reconstruct workflow state deterministically.

8. **Versioned**: Every event records the schema version it was written at, so an old log can be read after the code changes.

---

## Canonical Representation

There is no generic `%Event{type:, data:}`. Each event type is its own struct. Every one has an `id`, a `timestamp` and a `version`, plus the fields that fact needs. Nearly all also have a `workflow_id`.

```elixir
%Current.Event.EffectApplied{
  id: "sha256:c41d…",
  workflow_id: "sha256:77aa…",
  intent: %Current.Intent.EditFile{...},
  result: %Current.EffectResult.EditFile{...},
  timestamp: ~U[2026-03-21 15:00:07Z],
  version: 1
}
```

An event carries the intent and the result themselves. Their large contents are [artifacts](artifact.md), held by id.

### The event types

`Current.Event.t()` is the union of these structs, and `Current.Event.modules/0` is the closed set.

| Event | Records | Fields (besides `id`, `timestamp`, `version`) |
|---|---|---|
| `TaskCreated` | A task was submitted | `task_id`, `input`, `context`, `mode`, `project_dir`, `model`, `timeout_ms`, `submitted_at` |
| `WorkflowCreated` | A workflow began for a task | `workflow_id`, `task_id`, `mode`, `max_revisions` |
| `ProposalProductionStarted` | The model was asked for a proposal | `workflow_id` |
| `ModeInvalid` | The task's mode is not `:plan` or `:apply` | `workflow_id`, `mode` |
| `ProposalProduced` | A proposal was decoded from the model's reply | `workflow_id`, `proposal`, `raw_output_blob_id` |
| `ProposalProductionFailed` | No proposal could be produced | `workflow_id`, `error` |
| `ProposalValidated` | The proposal passed validation | `workflow_id`, `proposal` |
| `ProposalValidationFailed` | The proposal failed validation | `workflow_id`, `proposal`, `error` |
| `ProposalApproved` | A person approved the proposal | `workflow_id`, `proposal_id`, `metadata` |
| `ProposalRejected` | A person rejected the proposal | `workflow_id`, `proposal_id`, `metadata` |
| `ProposalRevisionRequested` | A reviewer sent the proposal back with feedback | `workflow_id`, `proposal_id`, `feedback`, `metadata` |
| `EffectApplicationStarted` | Applying the intents began | `workflow_id` |
| `EffectApplied` | One intent was applied | `workflow_id`, `intent`, `result` |
| `EffectFailed` | One intent failed | `workflow_id`, `intent`, `reason` |
| `EffectApplicationComplete` | Every intent was applied | `workflow_id`, `intent_results` |
| `WorkflowResultAssembled` | The result was assembled | `workflow_id`, `result` |
| `WorkflowCompleted` | The workflow ended successfully | `workflow_id` |
| `WorkflowFailed` | The workflow ended in failure | `workflow_id`, `reason` |
| `WorkflowAbandoned` | No further automatic progress is possible | `workflow_id`, `reason` |

`TaskCreated` has no `workflow_id`, so `Current.Event.lifecycle_modules/0` is every type but that one.

### Validation

There is no per-event validator. The type set is closed (`Current.Event.valid?/1` is true only for the structs above), each struct enforces its required keys, and `WorkflowReducer` refuses an event that is not a legal next step. See [validators.md](validators.md).

### Versions and upcasting

Events are written to the log as raw Erlang terms and read back as plain maps tagged with `__struct__`. Adding, removing or renaming a field changes what `%Event.X{}` means without changing what is on disk. So each event module declares a schema version:

```elixir
defmodule Current.Event.ProposalProduced do
  use Current.Event.Versioned, version: 4

  def upcast(fields, 1), do: fields

  # v3: Proposal gained :observations.
  def upcast(fields, 2), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)

  # v4: Proposal gained :revision and :revises.
  def upcast(fields, 3), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)
end
```

Reading an event goes through `Current.Event.Schema.upcast/1`, which applies `upcast(fields, from)` once per version until the event is current. The rules:

- Every version bump needs an `upcast/2` clause for the version being left behind. For a purely additive change it returns `fields` unchanged, and the struct's default fills the new field.
- A rename, a removed field or a changed meaning must be handled explicitly in that clause.
- Never delete an `upcast/2` clause. An old log may still need it.
- An event written by newer code than the one reading it raises `FutureVersionError`. A version with no upcast raises `UpcastError`.

Some changes cannot be migrated. `TaskCreated` v3 added a required `model` that no earlier record had, so a v2 task cannot be read at all, and its `upcast/2` says so.

---

## Breaking It Down

### 1. Immutable

An event is a permanent fact in the system. Once recorded, it must not change.

If the runtime makes a mistake, the fix is not:

> "edit the old event"

The fix is:

> "append a new event that corrects or supersedes it"

This is the foundation of auditability and replay.

### 2. Typed

An event belongs to a finite set of allowed event types.

Examples:

- `Event.TaskCreated`
- `Event.ProposalProduced`
- `Event.ProposalApproved`
- `Event.EffectApplied`
- `Event.WorkflowCompleted`

This forms the runtime's **algebra of facts**.

### 3. Record of the Past

This is the most important distinction. An event is not a request or a plan. It is a record that something has already happened.

❌ Not:

> "run tests"

✅ But:

> "the command ran and exited with code 1; its output is stored here"

### 4. Append-Only

Events are never updated in place. The log grows by appending new events, in hash-chained commits (see the [commit log notes](commit_log_design_notes.md)). This gives the system history, traceability, replayability and time-travel inspection.

### 5. Context-Bound

Every event belongs to a workflow, which is how a log of many workflows is told apart. The workflow's events, in order, are what `current events <id>` prints. Without a workflow, an event is not useful for reconstruction.

### 6. Replayable

Events are not just audit records. They are the raw material from which state is derived. The runtime does this on every start:

```
initial_state + event_log -> current_state
```

`WorkflowReducer.apply_event/2` takes the current workflow (or `nil` for the first event) and one event, and returns the next workflow. `WorkflowReducer.replay/1` folds a whole list. If replay is impossible, the event model is incomplete.

Some events change nothing but are still facts worth keeping. `EffectApplied`, `EffectFailed` and `EffectApplicationComplete` record what happened without moving the workflow's status.

---

## The Simplest Way to Think About It

> **An event is a committed fact in the system log.**

---

## Concrete Examples

**Example 1: Task created**

```elixir
%Current.Event.TaskCreated{
  task_id: "sha256:12ab…",
  input: "add email validation to signup flow",
  mode: :apply,
  project_dir: "/home/me/project",
  model: "anthropic:claude-opus-5-5",
  ...
}
```

Means: *"The runtime received this task."*

---

**Example 2: Proposal produced**

```elixir
%Current.Event.ProposalProduced{
  workflow_id: "sha256:77aa…",
  proposal: %Current.Proposal{intents: [...]},
  raw_output_blob_id: "sha256:c0de…"
}
```

Means: *"The model's reply was decoded into this proposal. The reply itself is kept as it arrived."*

---

**Example 3: Validation failed**

```elixir
%Current.Event.ProposalValidationFailed{
  workflow_id: "sha256:77aa…",
  proposal: %Current.Proposal{...},
  error: %Current.Error.ValidationError{
    intent_id: "sha256:9d2f…",
    reason: "edit_file old_string was not found in the file; ..."
  }
}
```

Means: *"This proposal was not accepted by the runtime, and this is why."*

---

**Example 4: Effect applied**

```elixir
%Current.Event.EffectApplied{
  workflow_id: "sha256:77aa…",
  intent: %Current.Intent.EditFile{...},
  result: %Current.EffectResult.EditFile{replacements: 1, ...}
}
```

Means: *"The interpreter applied the approved intent, and this is what it produced."*

---

## The Deeper Structure

Every event has:

1. **Type**: which struct it is, and so what fact is being recorded
2. **Id**: a random id, unique to this event
3. **Context**: the `workflow_id` it belongs to
4. **Timestamp**: when the fact occurred
5. **Version**: the schema version it was written at
6. **Fields**: the structured payload for that fact

---

## Where Events Sit in the System

```
Intent → Validation → Interpreter → Effect → Event → State
```

Events sit **after reality has moved**. An intent is a proposal; an event is the durable record of what followed.

---

## Why This Abstraction is Powerful

It lets you separate concerns cleanly:

| Concern | Layer |
|---|---|
| "What is proposed?" | Agent |
| "What is allowed?" | Validator |
| "What is executed?" | Interpreter |
| "What happened?" | Event |
| "What is currently true?" | Reducer/Projection |

---

## The Key Insight

Without events:

> the system only knows what it is doing right now

With events:

> the system knows what happened, in what order, and can reconstruct state from first principles

This is what makes replay possible, debugging tractable, state derivation deterministic, and audits meaningful.

---

## What an Event is NOT

❌ **Not an intent**: intents describe what is proposed; events describe what occurred.

❌ **Not mutable state**: state is derived from events; it is not the same thing as the event log.

❌ **Not a log line**: log lines are for humans; events are structured runtime facts.

---

## A Better Analogy

Think of an event like a **committed database transaction record**. It represents something that actually happened, becomes part of the permanent history, can be replayed to reconstruct state, and cannot be silently edited away.

---

## Minimal Mental Model

> **Event = Fact, expressed as data, after execution or decision.**

---

## Relationship to Intents

The distinction is fundamental.

**Intent**: a proposal before execution.

**Event**: a fact after execution or runtime decision.

Example flow:

```
Agent emits intent
→ Runtime validates intent
→ Interpreter applies effect
→ Runtime records event
→ Reducer derives new state
```

The runtime boundary is crossed here:

- **Intents** are how AI speaks to the system
- **Events** are how the system remembers what happened

---

## Design Constraint

> The current state of the runtime must be derivable from the event log and any immutable artifacts it references.

If this is not true, the event model is incomplete.

---

## The System in One Sentence

> *Intents propose change. Events record fact. State is derived from the event log.*

