# Current

**A deterministic runtime for AI workflows.**

Agents propose changes.
The runtime validates, records, and controls their execution.

Current separates cognition from execution.

The model may be probabilistic.
The runtime should not be.

Models propose structured intents.
Reducers derive workflow state.
Trusted interpreters apply effects.
Events and immutable artifacts form the system record.

Agents do not write files, run commands, or mutate the world directly. They describe intended changes. The runtime decides what actually happens.

Most systems let the agent edit files, run commands, and mutate the world directly. This is convenient. It also puts side effects inside a probabilistic system.

Current keeps side effects at the edge of the system.

> **AI workflows as pure state transitions, with effects at the edge.**

---

## The Idea

### Old model

Human asks the AI to do a task
→ AI mutates the world directly

#### Safer model

Human asks the system to do a task
→ Agent produces a proposal from the task and context
→ Runtime validates the proposal
→ If accepted, an interpreter may apply the effect
→ Events are recorded throughout
→ State is derived from the event log and referenced artifacts

The log is the canonical source of truth for how the system evolved.

---

## Why This Exists

If you let an agent act directly, you have to trust it. If you make it propose, you can reason about it.

You can:

- validate before execution
- simulate without side effects
- require approval
- replay everything
- inspect every decision

The model is still non-deterministic. The system around it does not have to be.

---

## System Flow

```text
Human Request
    ↓
Task
    ↓
Workflow is created
    ↓
Proposal
    ↓
Intents
    ↓
Artifacts
    ↓
WorkflowResult

Events are emitted throughout and form the canonical system record.
```

## Lifecycle

```
Task submitted
→ Workflow created (:created → :planning)

→ Proposal produced (:planning)
→ Proposal validated (:validating)

→ If approval required → waiting_for_approval
→ If approved → :approved

→ Intents applied (:applying)
→ Artifacts produced

→ WorkflowResult assembled (:assembling_result)

→ Workflow completes (:completed)
   or is rejected (:rejected)
   or fails (:failed)
```

Everything is recorded as events
Nothing is implicit

---

## Core Concepts

### Task
A task is the external ask submitted to the system.  
It is the thing the workflow is trying to accomplish.

### Workflow
A workflow is the system process created to carry a task from submission to outcome.  
It owns the proposal, the lifecycle events, and the final workflow result.

### Proposal
A proposal is a candidate response to a task, produced within a workflow.  
It groups one or more intents into a coherent unit of suggested work.

### Intent
An intent is the smallest unit of proposed work the runtime can evaluate independently.  
It describes one desired effect or observation.

### Artifact
An artifact is an immutable stored result produced by a step or runtime stage.  
It is what later steps, projections, and replay operate on.

### Event
An event is an immutable record of something that happened in the runtime.  
The event log is the canonical record of system evolution.

### State
State is a derived view computed from the event log and the immutable artifacts it references.  
It is not the primary source of truth.

---

## Design Principles

**1. Pure core, impure edge**

Workflow logic is modeled as pure state transitions over immutable data. Effects belong in a small, trusted interpreter layer.

**2. Intents over actions**

Agents describe intended mutations. They do not execute them.

**3. Event sourcing by default**

Everything important becomes an event: task submitted, workflow created, proposal produced, intents validated, effects applied, artifacts produced, workflow completed.

State is derived from the event log.

**4. Deterministic orchestration around non-deterministic models**

LLMs remain probabilistic. The scheduler, validator, interpreter, and state reducer should not be.

**5. Simulation before mutation**

Every pipeline supports: plan, dry run, sandbox apply, and real apply.

**6. Minimal trusted surface**

The most security-sensitive part of the system should be small, explicit, and testable.

---

## How Current Differs from Agent Tool Runtimes

| Concern | Typical agent runtime | Current |
|---|---|---|
| File edits | Agent edits directly | Agent proposes patch |
| Commands | Agent invokes shell | Agent requests command |
| Safety model | Prompt + tool permission | Typed intent + interpreter gate |
| State | Ad hoc workspace state | Event-sourced workflow state |
| Reproducibility | Partial | Strong |
| Dry run | Often weak | First-class |
| Replay | Limited | Built-in by design |

---

## Execution Modes

The same workflow can run in different modes.

The workflow structure remains the same, but the runtime controls:
- whether effects are applied
- whether approval is required
- whether artifacts are persisted

| Mode | Behavior |
|---|---|
| `plan` | Produce a proposal and intents only. No effects are applied. |
| `simulate` | Apply intents in a temporary environment. Artifacts are not persisted. |
| `review` | Validate intents and pause for approval before applying effects. |
| `apply` | Execute accepted intents through trusted interpreters and persist artifacts. |

---

## Example

Task: add email validation to signup flow

```text
→ A workflow is created  
→ The agent produces a proposal  
→ The proposal contains intents:
  - update signup logic
  - run tests

→ The runtime validates each intent  
→ Accepted intents are applied  
→ Artifacts are produced (patch result, test output)  
→ A workflow artifact is assembled  
```

Everything is recorded as events.

---

## What This Is Not

This is not a shell wrapper.
It is not a chat interface.
It is not an autonomous agent.

It does not try to make the model correct.

It describes change.
It controls when change is allowed.

---

## Determinism

The model may vary. The runtime should not.

- scheduling is deterministic
- validation is deterministic
- policy is deterministic
- interpretation is controlled
- events are append-only
- state is derived

If something changes, you can see exactly where and why.

---

## Safety

Current is designed around defense in depth:

1. Agents cannot perform effects directly
2. All intents are schema-validated
3. Policies decide what may be interpreted
4. Interpreters run in controlled environments
5. Every transition is recorded

This does not eliminate failure. It makes failure visible.

---

## Use Cases

Current is a good fit anywhere you want to plan first, apply later, and understand everything:

- code generation with approval gates
- repository maintenance
- refactoring pipelines
- documentation generation
- migration planning
- CI-assist workflows
- security review flows

---

## Why Pure Functional?

Because pure systems are easier to reason about. If everything is input → output, you can test it, replay it, debug it, and trust it. Side effects still exist — they just happen in one controlled place.

Current borrows from event sourcing, CQRS, typed effect systems, workflow engines, functional architecture, and actor-style orchestration.

---

## Roadmap

**Phase 1**

- workflow definition format
- intent schema
- append-only event log
- validator
- local file/command interpreter
- CLI for `plan` / `simulate` / `apply`

**Phase 2**

- approval policies
- sandbox environments
- artifact browser
- replay and time-travel inspection
- branch/worktree support

**Phase 3**

- distributed interpreters
- typed contracts between steps
- richer projections
- supervised long-running workflows
- plugin adapter system

**Phase 4**

- BEAM-native runtime
- process-per-step orchestration
- durable mailbox/event bridge
- fault-tolerant distributed execution

---

## Status

This is early. The goal is simple:

1. take a task
2. turn it into intents
3. validate them
4. optionally apply them
5. record everything
6. derive state
7. repeat

If that loop is solid, the rest follows.

---

## Hello World

Coming soon. Planned first demo:

```sh
current init
current plan "add input validation to signup form"
current simulate run feature/signup-validation
current apply run feature/signup-validation
current events tail
```

---

## Inspiration

Agent systems are powerful. Production systems need to be trustworthy. The two are not the same.

Current takes ideas from event sourcing, CQRS, functional programming, workflow engines, and distributed systems — and applies them to AI workflows. It takes seriously the idea that AI systems should be designed more like databases, compilers, and distributed systems, and less like shell scripts with better branding.

---

## Contributing

Contributions are welcome, especially in:

- intent algebra design
- event model design
- reducer/projection architecture
- sandbox interpreters
- workflow DSL design
- BEAM runtime ideas
- test harnesses and replay tooling

---

## License

MIT
