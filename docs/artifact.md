# What is an Artifact?

## Definition

An Artifact is:

> **An immutable, typed, stored object produced by a step or runtime stage, addressable by identity, and optionally bound to a named workflow output.**

If an intent is a proposal and an event is a fact, an artifact is a **result**.

An artifact does not describe what should happen, and it does not record what happened. It holds what was produced.

---

## Invariants

The following must always hold for any valid artifact:

1. **Immutable** — Once written, an artifact must not be modified. New versions must be written as new artifacts, not edits to existing ones.

2. **Addressable** — Every artifact must have a stable identity. Artifacts intended for downstream workflow use must also have a stable name within the scope of their run. The identity is canonical; the name is a workflow-level binding.

3. **Typed** — Every artifact must belong to a predefined, closed set of artifact types. Arbitrary or untyped blobs are not allowed.

4. **Serializable** — An artifact must be representable as data or a reference to stored data. It must not contain executable code.

5. **Context-bound** — Every artifact must be attributable to a specific step, task, and run.

6. **Not a proposal** — An artifact is not itself a proposal. It is a stored output produced by a step or runtime stage. This includes agent-produced outputs, runtime-produced outputs, and interpreter-produced outputs.

7. **Event-referenced** — Artifacts may be persisted before the corresponding event is appended, but they become part of durable runtime history only once referenced by an event. An artifact that is never referenced by an event is not part of the canonical run record.

---

## Canonical Representation

An artifact should be representable as a structured value.

```elixir
%Current.Artifact{
  id: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  name: :patch_output,
  type: :file_patch_result,
  storage: %{
    backend: :filesystem,
    path: "artifacts/sha256/ab/cd/abcdef..."
  },
  metadata: %{
    bytes: 1842,
    content_type: "text/x-diff"
  },
  context: %{
    step_id: "implement_auth",
    task_id: "task_123",
    run_id: "run_456"
  },
  timestamp: ~U[2026-03-21 15:00:10Z]
}
```

The artifact struct describes a stored object and its location. It does not inline the result data — that is owned by the store and addressed by `id`.

In v0, artifacts are stored on the local filesystem. The `storage` field is modeled explicitly so that future backends can be added without changing the artifact abstraction.

### Artifact Identity

Every artifact has two addresses:

- **Canonical identity** — the `id`, typically a content hash. Stable, storage-level, and intended to be unique within the artifact store.
- **Workflow name** — the `name` within a run. How steps refer to outputs within a pipeline.

These are kept separate intentionally. The `id` gives you storage integrity; the `name` gives you composability.

### Struct Definition

```elixir
defmodule Current.Id do
  @type t :: String.t()

  @sha256_prefix "sha256:"
  @sha256_hex_length 64

  def validate(@sha256_prefix <> hex) when byte_size(hex) == @sha256_hex_length do
    if String.match?(hex, ~r/\A[0-9a-f]+\z/) do
      :ok
    else
      {:error, :invalid_id_hex}
    end
  end

  def validate(_), do: {:error, :invalid_id}
end
```

```elixir
defmodule Current.Artifact do
  @enforce_keys [:id, :type, :storage, :metadata, :context, :timestamp]
  defstruct [
    :id,
    :name,
    :type,
    :storage,
    :metadata,
    :context,
    :timestamp
  ]

  @type type ::
          :file_patch_result
          | :command_result
          | :test_result
          | :read_result
          | :claim_result
          | :report
          | :manifest

  @type storage :: %{
          backend: :filesystem,
          path: String.t()
        }

  @type metadata :: %{
          optional(:bytes) => non_neg_integer(),
          optional(:content_type) => String.t()
        }

  @type context :: %{
          step_id: String.t(),
          task_id: String.t(),
          run_id: String.t()
        }

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          name: atom() | nil,
          type: type(),
          storage: storage(),
          metadata: metadata(),
          context: context(),
          timestamp: DateTime.t()
        }
end
```
### Artifact Reference

Steps do not pass artifacts directly. They pass references. This keeps the pipeline data model lightweight and allows the store to own the actual bytes.

```elixir
defmodule Current.ArtifactRef do
  @enforce_keys [:id, :name, :run_id]
  defstruct [
    :id,
    :name,
    :run_id,
    :type
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          name: atom(),
          run_id: String.t(),
          type: Current.Artifact.type() | nil
        }
end
```

`id` is the canonical storage address. `name` + `run_id` is the workflow address. Both are included so that refs work for both storage integrity checks and pipeline composition.

`ArtifactRef` is used for workflow-visible outputs. As a result, refs always include a `name`, even though stored artifacts themselves may be unnamed.

### Validation Rules

Every artifact must pass validation before it can be stored.

```elixir
defmodule Current.Artifact.Validator do
  alias Current.Artifact

  @valid_types [
    :file_patch_result,
    :command_result,
    :test_result,
    :read_result,
    :claim_result,
    :report,
    :manifest
  ]

  def validate(%Artifact{} = artifact) do
    with :ok <- validate_type(artifact.type),
         :ok <- validate_name(artifact.name),
         :ok <- Current.Id.validate(artifact.id),
         :ok <- validate_storage(artifact.storage),
         :ok <- validate_context(artifact.context),
         :ok <- validate_timestamp(artifact.timestamp),
         :ok <- validate_metadata(artifact.metadata) do
      :ok
    end
  end
  
  defp validate_name(nil), do: :ok
  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_storage(%{backend: :filesystem, path: p})
     when is_binary(p) and byte_size(p) > 0,
     do: :ok
  defp validate_storage(_), do: {:error, :invalid_storage}

  defp validate_context(%{step_id: s, task_id: t, run_id: r})
       when is_binary(s) and is_binary(t) and is_binary(r),
       do: :ok

  defp validate_context(_), do: {:error, :invalid_context}

  defp validate_timestamp(%DateTime{}), do: :ok
  defp validate_timestamp(_), do: {:error, :invalid_timestamp}

  defp validate_metadata(metadata) when is_map(metadata) do
    case metadata do
        %{bytes: bytes} when not is_integer(bytes) or bytes < 0 ->
            {:error, :invalid_metadata}
        %{content_type: ct} when not is_binary(ct) ->
            {:error, :invalid_metadata}
        _ -> :ok
    end
  end
  defp validate_metadata(_), do: {:error, :invalid_metadata}
end
```

Validation enforces:

- type must be from a closed set
- id must be present and non-empty
- storage must specify a valid backend and path
- context must include step, task, and run identifiers
- timestamp must be present and valid

If validation fails, the artifact must not be stored.

**Minimum required fields:**

- `id` — canonical artifact identity, currently encoded as a SHA-256 content address of the form sha256:<hex>
- `type` — atom identifying the artifact kind
- `storage` — backend and path where the artifact is stored
- `metadata` — structured descriptive fields such as size and content type
- `context` — origin metadata
- `timestamp` — when the artifact was produced

**Optional fields:**

- `name` — workflow-level name used when the artifact is bound to a named output within its run

In v0, artifacts are stored on the local filesystem. The `storage` field is modeled explicitly so that future backends (for example object stores or remote blob stores) can be added without changing the artifact abstraction.

---

## Breaking It Down

### 1. Addressable

An artifact has two levels of identity.

At the storage level, it has a canonical `id` — typically a content hash — that is stable and intended to be unique within the artifact store, regardless of which run produced it.

At the workflow level, it has a `name` within a run. This is what downstream steps use to declare what they need:

```elixir
%Current.ArtifactRef{
  id: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  name: :patch_output,
  run_id: "run_456"
}
```

Without the `id`, you lose storage integrity. When an artifact is exposed as a workflow output, a `name` provides pipeline composability. The `id` is always required. A `name` is required only when the artifact is intended to be referenced as a named workflow output.

### 2. Typed

Every artifact belongs to a closed set of types. This ensures the runtime knows how to store, validate, and project each artifact.

Examples:

- `:file_patch_result`
- `:command_result`
- `:test_result`
- `:report`
- `:manifest`

This forms the runtime's **algebra of outputs**.

### 3. Result

This is the most important distinction.

An artifact is not a proposal and not a record of process. It is the output that a step produced.

❌ Not: `"apply this patch"` — that is an intent.

❌ Not: `"patch was applied"` — that is an event.

✅ But: `"here is the result of the applied patch"` — that is an artifact.

### 4. Immutable

Once stored, an artifact cannot be changed.

If a step runs again, it produces a new artifact with a new `id`. The old one remains. This is what makes replay and time-travel inspection coherent.

### 5. Not a Proposal

An artifact is not proposed by the agent. It is produced by a step or runtime stage after work has been done.

This includes outputs from:

- the interpreter (after applying an effect)
- the runtime itself (e.g. a validation report or prepared diff)
- an agent step that directly produces structured output

The key property is that an artifact is never speculative. It represents something that was produced, not something that should be.

```
Intent proposed → Intent validated → Effect applied → Artifact persisted → Event recorded
```

### 6. Event-Referenced

Artifacts may be persisted to storage before the event log is updated. But an artifact only becomes part of the canonical run record once an event references it.

This means:

- the event log remains the source of truth for what happened
- artifacts are the durable objects that events point to
- a stored artifact with no corresponding event is not part of the run history

---

## The Simplest Way to Think About It

> **An artifact is a committed result — an immutable stored object that the runtime addresses by identity and the pipeline may address by name.**

---

## Concrete Examples

**Example 1 — Patch result**

```elixir
%Current.Artifact{
  id: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  name: :patch_output,
  type: :file_patch_result,
  storage: %{backend: :filesystem, path: "artifacts/sha256/ab/cd/abcdef..."},
  metadata: %{bytes: 1842, content_type: "text/x-diff"},
  context: %{step_id: "implement", task_id: "task_123", run_id: "run_456"},
  timestamp: ~U[2026-03-21 15:00:10Z]
}
```

Means: *"The patch was applied and the result is stored at this location."*

---

**Example 2 — Test result**

```elixir
%Current.Artifact{
  id: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  name: :test_output,
  type: :test_result,
  storage: %{backend: :filesystem, path: "artifacts/sha256/de/f4/def456..."},
  metadata: %{bytes: 512, content_type: "application/json"},
  context: %{step_id: "verify", task_id: "task_123", run_id: "run_456"},
  timestamp: ~U[2026-03-21 15:00:15Z]
}
```

Means: *"The test run completed and the result is stored."*

---

**Example 3 — Report**

```elixir
%Current.Artifact{
  id: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  name: :summary,
  type: :report,
  storage: %{backend: :filesystem, path: "artifacts/sha256/gh/i7/ghi789..."},
  metadata: %{bytes: 2048, content_type: "text/markdown"},
  context: %{step_id: "summarize", task_id: "task_123", run_id: "run_456"},
  timestamp: ~U[2026-03-21 15:00:20Z]
}
```

Means: *"The summarize step produced this human-readable output."*

---

**Example 4 — Manifest**

```elixir
%Current.Artifact{
  id: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  name: :manifest,
  type: :manifest,
  storage: %{backend: :filesystem, path: "artifacts/sha256/jk/l0/jkl012..."},
  metadata: %{bytes: 128, content_type: "application/json"},
  context: %{step_id: "summarize", task_id: "task_123", run_id: "run_456"},
  timestamp: ~U[2026-03-21 15:00:21Z]
}
```

Means: *"This run produced these named outputs."*

---

**Example 5 — Unnamed command transcript**

```elixir
%Current.Artifact{
  id: "sha256:5555555555555555555555555555555555555555555555555555555555555555",
  name: nil,
  type: :command_result,
  storage: %{
    backend: :filesystem,
    path: "artifacts/sha256/55/55/5555555555555555555555555555555555555555555555555555555555555555"
  },
  metadata: %{
    bytes: 912,
    content_type: "text/plain"
  },
  context: %{
    step_id: "verify",
    task_id: "task_123",
    run_id: "run_456"
  },
  timestamp: ~U[2026-03-21 15:00:18Z]
}
```

Means: *"The runtime stored the raw output of a command for audit and replay, but it was not exposed as a named workflow output."*

---

## The Deeper Structure

Every artifact has:

1. **ID** — canonical artifact identity, currently encoded as a SHA-256 content address of the form sha256:<hex>
2. **Name** — optional workflow-level address within its run
3. **Type** — what kind of output it is
4. **Storage** — where the artifact is durably held; in v0 this is the local filesystem, but the model is backend-aware
5. **Metadata** — size and content type hints
6. **Context** — which step, task, and run produced it
7. **Timestamp** — when it was produced

---

## Where Artifacts Sit in the System

```
Agent → Intent → Validation → Interpreter → Effect → Artifact persisted → Event recorded → State
```

Artifacts sit **between effect and event**. The effect produces the artifact; the event records that it happened and references it by `id`; the state projection makes it addressable by name within the run.

An artifact only enters the canonical run record once it is referenced by an event. The event log remains the source of truth. The artifact store holds what the log points to.

---

## Why This Abstraction is Powerful

It completes the three-primitive model:

| Primitive | When | Role |
|---|---|---|
| Intent | Before execution | Proposal |
| Artifact | After execution | Result |
| Event | After execution | Fact |

Without artifacts, results are implicit in events. That works until you need to replay, inspect, or hand off output between steps — at which point the model breaks down.

---

## The Key Insight

Without artifacts:

> results are buried in events or floating in unstructured workspace state

With artifacts:

> every meaningful step output can be stored as a typed, content-addressed artifact, and may be bound to a workflow name when downstream steps need to reference it

---

## What an Artifact is NOT

❌ **Not an intent** — intents are proposals; artifacts are results.

❌ **Not an event** — events record that something happened; artifacts hold what was produced. Events reference artifacts; they are not the same thing.

❌ **Not workspace state** — artifacts are immutable and addressed; workspace state is mutable and implicit.

❌ **Not a log** — logs are for humans; artifacts are structured runtime objects addressed by identity.

---

## A Better Analogy

Think of an artifact like a **build output in a CI system**:

- it is produced by a specific job
- it is stored under a known address
- it can be downloaded or passed to a later stage
- it does not change after it is written
- it can be inspected long after the job completed

The job's log records that it ran. The artifact holds what it produced. Both are necessary; neither replaces the other.

---

## Minimal Mental Model

> **Artifact = Immutable stored result, addressed by identity, and optionally bound to a workflow name.**

---

## Relationship to Intents and Events

The three primitives form a complete loop:

**Intent** — what the agent proposes should happen.

**Event** — what the runtime records as having happened.

**Artifact** — what the step actually produced, stored durably and referenced by events.

Example flow:

```
Agent emits intent
→ Runtime validates intent
→ Interpreter applies effect
→ Artifact persisted (id assigned)
→ Event recorded (references artifact id)
→ Reducer derives new state
→ Next step receives artifact ref
```

- **Intents** are how AI speaks to the system
- **Events** are how the system remembers what happened
- **Artifacts** are how steps hand durable results to each other and to projections

---

## Design Constraint

> Every meaningful output of a step must be stored as an artifact and referenced by an event. If it is not stored and referenced, it is not part of the canonical run record and cannot be replayed or inspected.

---

## The System in One Sentence

> *Intents propose change. Artifacts hold results. Events record fact. State is derived from the event log and the immutable artifacts it references.*


