# What is an Intent?

## Definition

An Intent is:

> **A declarative, typed proposal for a state change or observation, produced by an agent, that has not yet been executed.**

---

## Invariants

The following must always hold for any valid intent:

1. **No side effects** — An intent must not directly cause any mutation. It is purely descriptive.

2. **Serializable** — An intent must be representable as data (e.g. JSON, Erlang term). It must not contain executable code.

3. **Deterministic interpretation** — Interpretation should be as deterministic as the interpreter and execution environment allow. Any material environmental dependency must be made explicit or captured in resulting events.

4. **Finite type set** — All intents must belong to a predefined, closed set of types. Arbitrary or free-form intent types are not allowed.

5. **Context-bound** — Every intent belongs to exactly one proposal (`proposal_id`), and that proposal belongs to one workflow.

6. **Pre-execution only** — An intent must never claim that an effect has already occurred.

---

## Canonical Representation

There is no generic `%Intent{type:, payload:}`. Each intent type is its own struct, so the fields it needs are enforced where it is defined.

```elixir
%Current.Intent.EditFile{
  id: "sha256:9d2f…",
  proposal_id: "sha256:41ab…",
  path: "/project/lib/auth.ex",
  old_artifact_id: "sha256:5f2c…",   # the exact text to replace
  new_artifact_id: "sha256:a91e…",   # its replacement
  replace_all: false
}
```

Text is never inlined. The `old_string` and `new_string` bytes are stored as [artifacts](artifact.md), and the intent holds their ids. By the time a proposal is recorded, every path is absolute and inside the project.

### The intent types

| Struct | Fields (besides `id` and `proposal_id`) |
|---|---|
| `Intent.ReadFile` | `path` |
| `Intent.Glob` | `pattern`, `base_dir` (default `"."`) |
| `Intent.Grep` | `pattern`, `paths` |
| `Intent.WriteFile` | `path`, `contents_artifact_id` |
| `Intent.EditFile` | `path`, `old_artifact_id`, `new_artifact_id`, `replace_all` (default `false`) |
| `Intent.DeleteFile` | `path` |
| `Intent.RunCommand` | `cmd`, `args` (default `[]`) |
| `Intent.Claim` | `statement`, `evidence`, `expected` |
| `Intent.Report` | `summary` |

```elixir
defmodule Current.Intent do
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

  def modules()        # the closed set
  def valid?(intent)   # true only for those structs
end
```

`justification`, `claims` and `dependencies` are not on intents. They belong to the `Proposal` that holds them (see [types.md](types.md)).

### Validation

Validation is not a method on the intent. `IntentValidator` checks a whole proposal, intent by intent, before anyone is asked to approve it. The rules are in [validators.md](validators.md). If validation fails, the proposal is recorded as failed and none of it is applied.

**Minimum required fields:** `id`, `proposal_id`, and whatever the type needs (the table above).

---

## Breaking It Down

### 1. Declarative

It says *what* should happen, not *how* to do it.

❌ Not: `"open file, write this string, close file"`

✅ But: `"the file at auth.ex should have this text replaced with that"`

### 2. Typed

It belongs to a finite set of allowed operations.

Examples:

- `Intent.EditFile`
- `Intent.RunCommand`
- `Intent.ReadFile`
- `Intent.Claim`
- `Intent.Report`

This produces an **algebra of effects**.

### 3. Proposal

This is the most important word.

An intent is a **suggestion, not an action**. It has:

- no authority
- no side effects
- no guarantees

It is advisory and must be explicitly accepted by the runtime before any effect occurs.

### 4. State Change or Observation

There are two broad categories:

**A. Mutations** (proposed changes)

- write file
- edit file
- delete file
- run command

**B. Observations** (requests or claims)

- read file
- glob and grep
- claim: "this invariant holds"

### 5. Not Yet Executed

This is the core shift.

Without intents:

```
agent → executes
```

With intents:

```
agent → proposes → runtime decides → maybe executes
```

---

## The Simplest Way to Think About It

> **An intent is a transaction that has not been committed.**

---

## Concrete Examples

**Example 1 — File change**

```elixir
%Intent.EditFile{path: "lib/auth.ex", old_artifact_id: old_id, new_artifact_id: new_id}
```

Means: *"I propose replacing this exact text in this file"* — not *"I have edited this file."*

---

**Example 2 — Command**

```elixir
%Intent.RunCommand{cmd: "mix", args: ["test"]}
```

Means: *"Tests should be run"* — not *"Tests have been run."*

---

**Example 3 — Claim**

```elixir
%Intent.Claim{
  statement: "the tests pass",
  evidence: %{source_intent_id: test_run_id, condition: :exit_code_equals, value: 0}
}
```

Means: *"I assert this is true, and here is the result that will show it"* — not *"This is verified truth."* A claim must cite an earlier intent; it is checked against that intent's result when applied, and a claim that doesn't hold fails the workflow.

---

**Example 4 — Read request**

```elixir
%Intent.ReadFile{path: "lib/user.ex"}
```

Means: *"I need this data to proceed."*

---

## The Deeper Structure

Every intent has:

1. **Type** — what kind of effect (its struct)
2. **Fields** — the data needed to execute it; large text as artifact ids
3. **Identity** — its own `id` and the `proposal_id` it belongs to
4. **Justification** *(optional)* — why it exists, stated on the proposal

---

## Where Intents Sit in the System

```
Agent → Intent → Validation → Interpreter → Effect → Event → State
```

Intent is the **boundary between AI and reality**.

---

## Why This Abstraction is Powerful

It lets you separate concerns cleanly:

| Concern | Layer |
|---|---|
| "What should happen?" | Agent |
| "Is this allowed?" | Validator |
| "How to do it?" | Interpreter |
| "What actually happened?" | Event |
| "What is the system state?" | Reducer |

---

## The Key Insight

Without intents:

> AI directly mutates the world.

With intents:

> AI describes desired mutations → the system governs them.

---

## What an Intent is NOT

❌ **Not a command** — commands execute immediately.

❌ **Not an event** — events represent what *happened*; intents represent what is *proposed*.

❌ **Not a log** — logs are passive; intents are actionable proposals.

---

## A Better Analogy

Think of an intent like a **Git patch before `git apply`**:

- it describes a change
- it can be reviewed
- it can be rejected
- it can be modified
- it can be applied later

---

## Minimal Mental Model

> **Intent = Proposed effect, expressed as data, before execution.**

---

## The System in One Sentence

> *"Agents emit intents. The runtime decides which ones become reality."*

