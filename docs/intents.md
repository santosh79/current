# What is an Intent?

An Intent is:

> **A declarative, typed proposal for a state change or observation, produced by an agent, that has not yet been executed.**

Let's break that down carefully.

---

## 1. "Declarative"

It says *what* should happen, not *how* to do it.

❌ Not: `"open file, write this string, close file"`

✅ But: `"the file at auth.ex should be updated with this patch"`

---

## 2. "Typed"

It belongs to a finite set of allowed operations.

Examples:

- `:file_patch`
- `:run_command`
- `:read_file`
- `:claim`
- `:report`

This is your **algebra of effects**.

---

## 3. "Proposal"

This is the most important word.

An intent is a **suggestion, not an action**. It has:

- no authority
- no side effects
- no guarantees

It is advisory.

---

## 4. "State change or observation"

There are two broad categories:

**A. Mutations** (proposed changes)

- write file
- delete file
- run command

**B. Observations** (requests or claims)

- read file
- run test
- "this invariant holds"

---

## 5. "Not yet executed"

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

## The simplest way to think about it

> **An intent is a transaction that has not been committed.**

---

## Concrete Examples

**Example 1 — File change**

```elixir
{:file_patch, "lib/auth.ex", diff}
```

Means: *"I propose this patch be applied to this file"* — not *"I have applied this patch."*

**Example 2 — Command**

```elixir
{:run_command, ["mix", "test"]}
```

Means: *"Tests should be run"* — not *"Tests have been run."*

**Example 3 — Claim**

```elixir
{:claim, "signup rejects invalid email"}
```

Means: *"I assert this is true"* — not *"This is verified truth."*

**Example 4 — Read request**

```elixir
{:read_file, "lib/user.ex"}
```

Means: *"I need this data to proceed."*

---

## The Deeper Structure

Every intent has:

1. **Type** — what kind of effect
2. **Payload** — data needed to execute it
3. **Context** — which step / agent / task it belongs to
4. **Justification** *(optional)* — why it exists

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

## The Mistake to Avoid

Do not let intents become arbitrary blobs, untyped JSON chaos, or a pass-through for whatever the LLM returns. Keep them **small, finite, and strongly typed**.

---

## The System in One Sentence

> *"Agents emit intents. The runtime decides which ones become reality."*

