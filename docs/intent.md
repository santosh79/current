# What is an Intent?

## Definition

An Intent is:

> **A declarative, typed proposal for a state change or observation, produced by an agent, that has not yet been executed.**

---

## Invariants

The following must always hold for any valid intent:

1. **No side effects** — An intent must not directly cause any mutation. It is purely descriptive.

2. **Serializable** — An intent must be representable as data (e.g. JSON, Erlang term). It must not contain executable code.

3. **Deterministic interpretation** — Given the same intent and environment, the interpreter should behave deterministically.

4. **Finite type set** — All intents must belong to a predefined, closed set of types. Arbitrary or free-form intent types are not allowed.

5. **Context-bound** — Every intent must be attributable to a specific step and task.

6. **Pre-execution only** — An intent must never claim that an effect has already occurred.

---

## Canonical Representation

An intent should be representable as a structured value.

```elixir
%Current.Intent{
  type: :file_patch,
  payload: %{
    path: "lib/auth.ex",
    diff: "...unified diff..."
  },
  context: %{
    step_id: "implement_auth",
    task_id: "task_123"
  },
  justification: "Add email validation"
}
```

### Struct Definition

```elixir
defmodule Current.Intent do
  @enforce_keys [:type, :payload, :context]
  defstruct [
    :type,
    :payload,
    :context,
    :justification,
    :claims,
    :dependencies
  ]

  @type type ::
          :file_patch
          | :write_file
          | :delete_file
          | :run_command
          | :read_file
          | :glob
          | :grep
          | :claim
          | :report

  @type t :: %__MODULE__{
          type: type(),
          payload: map(),
          context: %{
            step_id: String.t(),
            task_id: String.t()
          },
          justification: String.t() | nil,
          claims: [String.t()] | nil,
          dependencies: [String.t()] | nil
        }
end
```

### Validation Rules

Every intent must pass validation before it can be accepted by the runtime.

```elixir
defmodule Current.Intent.Validator do
  alias Current.Intent

  @valid_types [
    :file_patch,
    :write_file,
    :delete_file,
    :run_command,
    :read_file,
    :glob,
    :grep,
    :claim,
    :report
  ]

  def validate(%Intent{} = intent) do
    with :ok <- validate_type(intent.type),
         :ok <- validate_payload(intent),
         :ok <- validate_context(intent.context) do
      :ok
    end
  end

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_context(%{step_id: s, task_id: t})
       when is_binary(s) and is_binary(t),
       do: :ok

  defp validate_context(_), do: {:error, :invalid_context}

  defp validate_payload(%Intent{type: :file_patch, payload: %{path: p, diff: d}})
       when is_binary(p) and is_binary(d),
       do: :ok

  defp validate_payload(%Intent{type: :run_command, payload: %{cmd: cmd}})
       when is_list(cmd),
       do: :ok

  defp validate_payload(%Intent{type: :read_file, payload: %{path: p}})
       when is_binary(p),
       do: :ok

  defp validate_payload(%Intent{type: :claim, payload: %{value: v}})
       when is_binary(v),
       do: :ok

  defp validate_payload(%Intent{type: :report, payload: %{data: _}}),
       do: :ok

  defp validate_payload(_), do: {:error, :invalid_payload}
end
```

Validation enforces:

- type must be from a closed set
- payload must match the type
- context must be present and well-formed

If validation fails, the intent must be rejected and must not proceed to interpretation.

**Minimum required fields:**

- `type` — atom identifying the intent kind
- `payload` — structured data required for execution
- `context` — origin metadata

**Optional fields:** `justification`, `claims`, `dependencies`

---

## Breaking It Down

### 1. Declarative

It says *what* should happen, not *how* to do it.

❌ Not: `"open file, write this string, close file"`

✅ But: `"the file at auth.ex should be updated with this patch"`

### 2. Typed

It belongs to a finite set of allowed operations.

Examples:

- `:file_patch`
- `:run_command`
- `:read_file`
- `:claim`
- `:report`

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
- delete file
- run command

**B. Observations** (requests or claims)

- read file
- run test
- "this invariant holds"

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
{:file_patch, "lib/auth.ex", diff}
```

Means: *"I propose this patch be applied to this file"* — not *"I have applied this patch."*

---

**Example 2 — Command**

```elixir
{:run_command, ["mix", "test"]}
```

Means: *"Tests should be run"* — not *"Tests have been run."*

---

**Example 3 — Claim**

```elixir
{:claim, "signup rejects invalid email"}
```

Means: *"I assert this is true"* — not *"This is verified truth."*

---

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

## The System in One Sentence

> *"Agents emit intents. The runtime decides which ones become reality."*

