# Current

**A runtime for AI workflows where agents propose changes instead of performing them directly.**

Agents do not write files, run shell commands, or mutate the world on their own. They describe what should happen. The system decides what actually happens.

Most systems let the agent edit files, run commands, and mutate the world directly. This is convenient. It also puts side effects inside a probabilistic system.

Current separates the two.

> **AI workflows as pure state transitions, with effects at the edge.**

---

## The Idea

Instead of this:

```
Agent -> shell / files / network -> changed world
```

Current works like this:

```
Agent -> Intent
Intent -> Validation
Validation -> Decision
Decision -> Optional effect
Effect -> Recorded event -> New state
```

The agent describes. The system decides.

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

## The Shape of the System

There are three primitives:

- **Intents** — what is proposed
- **Artifacts** — what was produced
- **Events** — what happened

Everything else is derived. State is not stored — it is computed from the event log and the artifacts it references.

---

## Intents

An intent is a typed proposal. It says what should happen, not how to do it. A patch. A command. A claim. A request.

```json
{
  "step_id": "implement_auth",
  "intents": [
    {
      "type": "file_patch",
      "path": "lib/auth.ex",
      "patch": "...unified diff..."
    },
    {
      "type": "run_command",
      "command": ["mix", "test", "test/auth_test.exs"]
    }
  ],
  "claims": [
    "adds email validation",
    "does not change login behavior"
  ]
}
```

This can be validated, rejected, simulated, or applied. Nothing happens until the system allows it.

---

## Design Principles

**1. Pure core, impure edge**

Workflow logic is modeled as pure state transitions over immutable data. Effects belong in a small, trusted interpreter layer.

**2. Intents over actions**

Agents describe intended mutations. They do not execute them.

**3. Event sourcing by default**

Everything important becomes an event: task submitted, step scheduled, intent proposed, validation passed, effect applied, effect rejected, pipeline completed. State is derived from the event log.

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

## A Workflow

A workflow is a graph of steps. Each step produces data, not effects.

```
navigate -> specify -> implement -> verify -> summarize
```

One step proposes a patch. Another asks to run tests. Another decides whether the result is acceptable. The runtime coordinates this. Effects are optional. Control is explicit.

---

## Execution Modes

The same workflow can run in different modes. The workflow does not change — only the interpreter does.

| Mode | Behavior |
|---|---|
| `plan` | Produce intents only. No effects are executed. |
| `simulate` | Apply intents in a temporary workspace. |
| `review` | Require approval before effects. |
| `apply` | Perform real effects through trusted interpreters. |

---

## Example

**Task:** `add email validation to signup flow`

**Agent output:**

```json
{
  "step": "implement",
  "intents": [
    {
      "type": "file_patch",
      "path": "lib/my_app/signup.ex",
      "patch": "...diff..."
    },
    {
      "type": "run_command",
      "command": ["mix", "test", "test/my_app/signup_test.exs"]
    }
  ],
  "claims": [
    "invalid emails are rejected",
    "existing behavior is unchanged"
  ]
}
```

**Runtime behavior:**

1. Validate the schema
2. Check policy
3. Optionally apply the patch in a sandbox
4. Run tests through an interpreter
5. Capture results
6. Record events
7. Derive new state
8. Schedule the next step

Nothing is implicit. Everything is visible.

---

## Architecture

```
            +----------------------+
            |      Workflow        |
            |      Definition      |
            +----------+-----------+
                       |
                       v
            +----------------------+
            |      Scheduler        |
            |   deterministic DAG   |
            +----------+-----------+
                       |
                       v
            +----------------------+
            |        Agent          |
            |   returns intents     |
            +----------+-----------+
                       |
                       v
            +----------------------+
            |      Validator        |
            | schema/policy/checks  |
            +----------+-----------+
                       |
                +------+------+
                |             |
                v             v
      +----------------+   +------------------+
      | Event Store    |   | Effect Interpreter |
      | append-only    |   | file/shell/git/etc |
      +--------+-------+   +---------+--------+
               |                     |
               +----------+----------+
                          |
                          v
                +----------------------+
                |   State Projection    |
                | pipeline/run/artifacts|
                +----------------------+
```

---

## Core Concepts

**Workflow** — A graph of steps with dependencies, contracts, and policies.

**Step** — A unit of work assigned to an agent role.

**Intent** — A typed proposal describing a desired effect or observation.

**Artifact** — An immutable output produced by a step and stored by the runtime.

**Event** — An immutable record of what happened.

**Projection** — A derived read model of workflow state, run history, artifacts, and outcomes.

---

## What This Is Not

This is not a shell wrapper.
It is not a chat interface.
It is not an autonomous agent.

It does not try to make the model correct.

It describes change.
It controls when change is allowed.

---

## Intent Types

The system starts with a deliberately small algebra of effects.

**Read**

- `read_file`
- `glob`
- `grep`
- `git_diff`
- `git_log`

**Mutate**

- `file_patch`
- `write_file`
- `delete_file`

**Execute**

- `run_command`
- `run_test`
- `run_formatter`

**Control**

- `request_approval`
- `reject_step`
- `retry_step`
- `handoff`

**Report**

- `report`
- `claim`
- `artifact`

Each intent is typed and validated before interpretation.

---

## Event Model

- `TaskSubmitted`
- `StepScheduled`
- `StepStarted`
- `IntentProposed`
- `IntentValidated`
- `IntentRejected`
- `EffectApplied`
- `EffectFailed`
- `ClaimVerified`
- `StepCompleted`
- `PipelineCompleted`

All durable state is derived from these events.

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
