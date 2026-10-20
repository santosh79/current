# What is an Artifact?

## Definition

An Artifact is:

> **An immutable blob of bytes, stored once and addressed by the SHA-256 of its content.**

If an intent is a proposal and an event is a fact, an artifact is the **content** that proposals and facts point at.

An artifact does not describe what should happen, and it does not record what happened. It holds bytes: a file's text, the text an edit replaces, a command's output, the model's reply.

---

## Invariants

The following hold for every artifact:

1. **Immutable**: Once written, an artifact is never modified. Different bytes are a different artifact with a different id.

2. **Content-addressed**: The id is `"sha256:" <> hex(sha256(bytes))`. The same bytes always have the same id, so storing them twice stores them once.

3. **Just bytes**: An artifact has no type, name or metadata of its own. What the bytes *are* is known only from the field that references them (`contents_artifact_id`, `old_artifact_id`, `stdout_artifact_id`, and so on).

4. **Referenced by id, never embedded**: Intents, observations, effect results and events hold artifact ids, not contents. This keeps them small enough to live in the log.

5. **Event-referenced**: An artifact is written *before* the event that mentions it, so one can exist without being part of the record. It becomes part of durable history only once an event (directly, or through an intent, proposal or result inside an event) refers to it.

---

## Representation

There is no `Artifact` struct. The store is `Current.BlobStore`:

```elixir
Current.BlobStore.put(binary)          # {:ok, "sha256:<hex>"}; writes nothing if already stored
Current.BlobStore.read(id)             # {:ok, binary} | {:error, :not_found}
Current.BlobStore.path_for(id)         # {:ok, path}   | {:error, :not_found}
Current.BlobStore.ids_with_prefix(p)   # ids starting with "sha256:6c8e06", to resolve a short id
```

On disk, the blob for `sha256:<hex>` is the file `<data_dir>/artifacts/sha256-<hex>`. The local filesystem is the only backend.

### Artifact ids and other ids

Events, intents, proposals, tasks and workflows also have ids that start `sha256:`, but those are random (`Current.Id.generate/0`). Only an artifact's id is a hash of its content. Treat the two kinds as unrelated.

---

## What gets stored

Every field that holds an artifact id, and what is behind it:

| Where | Field | The bytes are |
|---|---|---|
| `Intent.WriteFile` | `contents_artifact_id` | the text of the file to create |
| `Intent.EditFile` | `old_artifact_id`, `new_artifact_id` | the exact text to replace, and its replacement |
| `EffectResult.ReadFile` | `contents_artifact_id` | the file as read |
| `EffectResult.EditFile` | `before_artifact_id`, `after_artifact_id` | the file before and after the edit |
| `EffectResult.DeleteFile` | `before_artifact_id` | the file as it was when deleted |
| `EffectResult.Command` | `stdout_artifact_id`, `stderr_artifact_id` | the command's output |
| `EffectResult.Glob`, `EffectResult.Grep` | `matches_artifact_id` | the match listing |
| `EffectResult.Grep` | `searched_artifact_ids` | the files that were searched |
| `Observation` | `artifact_id` | what the agent was shown |
| `Observation` | `reply_artifact_id` | the model reply that asked for it, untouched |
| `Event.ProposalProduced`, `ProposalProductionError` | `raw_output_blob_id` | the model's exact reply |

The event-side field is called `raw_output_blob_id`. It is an artifact id like the rest.

---

## Breaking It Down

### 1. Addressable

An artifact has one address: its content hash. The CLI uses it directly:

```sh
current artifact <artifact-id>      # the exact bytes, for piping
```

Ids can be shortened to any unique prefix of 4 or more hex digits.

### 2. A result, or an input

Most artifacts are produced by applying an effect: a file as it was, a command's output. Some are inputs captured on the way in: the text an edit will replace, a file's new contents, the model's raw reply. Either way the artifact is what was or will be there, not a description of it.

❌ Not: `"apply this edit"`: that is an intent.

❌ Not: `"edit was applied"`: that is an event.

✅ But: the file as it was before, and as it is after: those are artifacts.

### 3. Immutable

Once stored, an artifact cannot be changed. If a step runs again and produces different bytes, they get a new id. The old one remains. That is what makes replay and inspection coherent.

### 4. Event-referenced

Artifacts may be written before the event log is updated. But an artifact only becomes part of the record once an event refers to it.

- the event log remains the source of truth for what happened
- artifacts are the durable objects that events point to
- a stored artifact nothing refers to is not part of any workflow's history

```
Intent proposed → Intent validated → Effect applied → Artifact stored → Event recorded
```

---

## Concrete Examples

**Example 1: Edit result**

```elixir
%Current.EffectResult.EditFile{
  path: "/project/lib/auth.ex",
  before_artifact_id: "sha256:5f2c…",   # the file before the edit
  after_artifact_id: "sha256:a91e…",    # the file after
  replacements: 1
}
```

Means: *"The edit was applied once, and here are the exact bytes before and after."*

---

**Example 2: Command output**

```elixir
%Current.EffectResult.Command{
  exit_code: 0,
  stdout_artifact_id: "sha256:77b0…",
  stderr_artifact_id: "sha256:e3b0…",   # the hash of empty output
  stdout_bytes: 912,
  stderr_bytes: 0
}
```

Means: *"The command ran; its output is stored and can be read back byte for byte."*

---

**Example 3: The model's reply**

```elixir
%Current.Event.ProposalProduced{
  workflow_id: "sha256:…",
  proposal: %Current.Proposal{...},
  raw_output_blob_id: "sha256:c0de…"    # exactly what the model said
}
```

Means: *"This proposal was decoded from this reply, which is kept as it arrived."*

---

## Where Artifacts Sit in the System

```
Agent → Intent → Validation → Interpreter → Effect → Artifact stored → Event recorded → State
```

Artifacts sit **between effect and event**. The effect produces them; the event records that it happened and carries the effect result, which refers to them by id. Inputs (an edit's `old_string`, a file's new contents) are stored earlier, when the model's reply is decoded.

An artifact only enters the record once an event refers to it. The event log remains the source of truth. The artifact store holds what the log points to.

---

## Why This Abstraction is Powerful

It completes the three-primitive model:

| Primitive | When | Role |
|---|---|---|
| Intent | Before execution | Proposal |
| Event | After execution | Fact |
| Artifact | Throughout | The bytes both of them point at |

Without artifacts, file contents and command output would live inside events, and the log would grow with every byte. Content addressing also deduplicates for free: reading the same file twice stores it once.

---

## What an Artifact is NOT

❌ **Not an intent**: intents are proposals; artifacts are bytes.

❌ **Not an event**: events record that something happened; artifacts hold what it involved. Events reference artifacts; they are not the same thing.

❌ **Not typed or named**: there is no artifact type, name or storage descriptor. The field that holds the id says what the bytes are.

❌ **Not workspace state**: artifacts are immutable and addressed; workspace state is mutable and implicit.

❌ **Not a log**: logs are for humans; artifacts are addressed bytes.

---

## A Better Analogy

Think of the artifact store as a **Git object store**:

- an object is named by the hash of its content
- the same content is stored once
- objects never change
- commits (here, events) refer to objects by hash

---

## Minimal Mental Model

> **Artifact = Immutable bytes, addressed by their SHA-256.**

---

## Relationship to Intents and Events

**Intent**: what the agent proposes should happen.

**Event**: what the runtime records as having happened.

**Artifact**: the bytes either of them refers to, stored durably.

Example flow:

```
Agent emits intent (edit_file, with old and new text stored as artifacts)
→ Runtime validates intent
→ Interpreter applies effect (stores the file before and after as artifacts)
→ Event recorded (EffectApplied: the intent and its result, with artifact ids)
→ Reducer derives new state
```

- **Intents** are how AI speaks to the system
- **Events** are how the system remembers what happened
- **Artifacts** are where the bytes live

---

## Design Constraint

> Anything too large or too raw to live in an event is stored as an artifact and referenced by id. If it is not referenced by an event, it is not part of the record.

---

## The System in One Sentence

> *Intents propose change. Artifacts hold bytes. Events record fact. State is derived from the event log and the immutable artifacts it references.*

