# Intent

## Definition

An **Intent** is:

> a **declarative, typed proposal for a state change or observation**, produced by an agent, that has **not yet been executed**

It represents what *should* happen — not what *has* happened.

---

## Core Properties

### 1. Declarative

An intent describes **what should happen**, not how to do it.

❌ Not:

> “open file, write this string, close file”

✅ But:

> “the file at `auth.ex` should be updated with this patch”

---

### 2. Typed

An intent belongs to a **finite, well-defined set of operations**.

Examples:

- `:file_patch`
- `:run_command`
- `:read_file`
- `:claim`
- `:report`

This forms the system’s **algebra of effects**.

---

### 3. Proposal (Not Authority)

An intent is a **suggestion, not an action**.

It has:

- no authority
- no side effects
- no guarantees

It is **advisory**.

---

### 4. State Change or Observation

Intents fall into two broad categories:

#### A. Mutations (proposed changes)

- write file
- delete file
- run command

#### B. Observations (requests or assertions)

- read file
- run test
- declare a claim (e.g. “this invariant holds”)

---

### 5. Not Yet Executed

An intent is always **pre-execution**.

**Traditional systems:**

agent → executes

**Current:**

agent → proposes → runtime decides → maybe executes

---

## Mental Model

> **An intent is a transaction that has not been committed.**

---

## Examples

### File Change

```code
{:file_patch, "lib/auth.ex", diff}
```

Means:

“I propose this patch be applied to this file”

Not:

“I have applied this patch”

⸻
Command Execution

```code
{:run_command, ["mix", "test"]}
```

Means:

“Tests should be run”

Not:

“Tests have been run”

⸻

Claim

```code
{:claim, "signup rejects invalid email"}
```

Means:

“I assert this is true”

Not:

“This is verified truth”

⸻

Read Request

```code
{:read_file, "lib/user.ex"}
```

Means:

“I need this data to proceed”

⸻

Structure

Every intent consists of:
	1.	Type
What kind of effect is being proposed
	2.	Payload
The data required to interpret or execute it
	3.	Context
The originating step, agent, or task
	4.	(Optional) Justification
Why the intent exists

⸻

Role in the System

Agent → Intent → Validation → Interpreter → Effect → Event → State

The intent is:

the boundary between AI and reality

⸻

Separation of Concerns

Intents enable a clean separation of responsibilities:

Concern	Layer
What should happen?	Agent
Is this allowed?	Validator
How is it executed?	Interpreter
What actually happened?	Event
What is current state?	Reducer

Why Intents Matter

Without intents:

AI directly mutates the world

With intents:

AI proposes changes → system governs execution

This reduces risk and increases:
	•	auditability
	•	reproducibility
	•	control
	•	debuggability

⸻

What an Intent is NOT

Not a Command

Commands execute immediately.
Intents do not.

⸻

Not an Event

Events represent what happened.
Intents represent what is proposed.

⸻

Not a Log

Logs are passive records.
Intents are actionable proposals.

⸻

Analogy

An intent is like:

a Git patch before git apply

It:
	•	describes a change
	•	can be reviewed
	•	can be rejected
	•	can be modified
	•	can be applied later

⸻

Minimal Model

If you remember one thing:

Intent = Proposed effect, expressed as data, before execution

⸻

Constraints

To keep the system reliable, intents must be:
	•	small
	•	finite
	•	strongly typed

Avoid:
	•	arbitrary blobs
	•	untyped JSON
	•	free-form agent outputs

⸻

System Summary

Agents emit intents. The runtime decides which ones become reality.

