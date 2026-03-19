# Current

**A pure-functional orchestration runtime for AI workflows.**

Current is an open-source runtime for building AI systems that propose changes instead of performing them directly.

Agents do not write files, run shell commands, or mutate the world on their own. They return **structured intents** — patches, command requests, claims, and handoff artifacts — which are validated, recorded, and optionally interpreted by a trusted runtime.

Think of it as:

> **AI workflows as pure state transitions, with effects at the edge.**

---

## Why Current?

Most agent orchestration systems give LLMs tool access and then try to contain the blast radius with prompts, permissions, and sandboxes.

That helps, but it still puts side effects too close to a probabilistic core.

Current takes a different approach:

- **Agents propose**
- **Runtime validates**
- **Interpreter applies**
- **Event log remembers everything**

The result is a system that is easier to:

- audit
- replay
- test
- simulate
- compose
- trust

---

## Core Idea

Instead of this:

```text
Agent -> shell/file/git/network -> changed world

Current works like this:

Agent -> Intent
Intent -> Validation
Validation -> Runtime decision
Runtime -> Optional effect interpreter
Interpreter -> Applied result
Applied result -> Event log -> New workflow state

Agents describe what should happen.

The runtime decides what actually happens.

⸻

What is an Intent?

An intent is a typed proposal emitted by an agent step.

Examples:
	•	a patch to apply to a file
	•	a request to run tests
	•	a claim that must be verified
	•	a structured handoff to another step
	•	a request to fetch or inspect project state

Example:

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
      "command": ["mix", "test", "test/auth_test.exs"],
      "reason": "verify authentication behavior"
    }
  ],
  "claims": [
    "adds email validation to signup flow",
    "does not change existing login semantics"
  ]
}

This data can be validated, simulated, reviewed, or applied.

⸻

Design Principles

1. Pure core, impure edge

Workflow logic should be modeled as pure state transitions over immutable data.

Effects belong in a small, trusted interpreter layer.

2. Intents over actions

Agents should describe intended mutations, not execute them directly.

3. Event sourcing by default

Everything important becomes an event:
	•	task submitted
	•	step scheduled
	•	intent proposed
	•	validation passed
	•	effect applied
	•	effect rejected
	•	pipeline completed

The current state of the system is derived from the event log.

4. Deterministic orchestration around non-deterministic models

LLMs remain probabilistic. The scheduler, validator, interpreter, and state reducer should not be.

5. Simulation before mutation

Every pipeline should support:
	•	plan
	•	dry run
	•	sandbox apply
	•	real apply

6. Minimal trusted surface

The most security-sensitive part of the system should be small, explicit, and testable.

⸻

How Current Differs from Agent Tool Runtimes

Concern	Typical agent runtime	Current
File edits	Agent edits directly	Agent proposes patch
Commands	Agent invokes shell	Agent requests command
Safety model	Prompt + tool permission	Typed intent + interpreter gate
State	Ad hoc workspace state	Event-sourced workflow state
Reproducibility	Partial	Strong
Dry run	Often weak	First-class
Replay	Limited	Built-in by design


⸻

Example Workflow

A typical feature pipeline might look like this:

navigate -> specify -> implement -> verify -> summarize

But each step produces data, not direct side effects.

Navigate

Returns:
	•	affected files
	•	project map
	•	risk notes

Specify

Returns:
	•	acceptance criteria
	•	invariants
	•	expected contracts

Implement

Returns:
	•	proposed patches
	•	requested test runs
	•	claims about behavior

Verify

Returns:
	•	verdict
	•	failed invariants
	•	approval or rejection intents

Summarize

Returns:
	•	final report
	•	changelog
	•	artifact manifest

⸻

Execution Modes

Current supports multiple modes for the same workflow:

plan

Only produce intents. No effects are executed.

simulate

Apply intents in an isolated temporary workspace.

review

Require human or policy approval before selected effects.

apply

Allow trusted interpreters to apply approved effects.

⸻

Example

Task

add email validation to signup flow

Agent output

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
    "existing successful signup flow remains unchanged"
  ]
}

Runtime behavior
	1.	Validate the schema
	2.	Check policy
	3.	Optionally apply patch in sandbox
	4.	Run requested test command via interpreter
	5.	Capture results
	6.	Emit events
	7.	Reduce new workflow state
	8.	Schedule next step

⸻

Architecture

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


⸻

Core Concepts

Workflow

A graph of steps with dependencies, contracts, and policies.

Step

A unit of work assigned to an agent role.

Intent

A typed proposal describing a desired effect or artifact.

Interpreter

A trusted component that can turn approved intents into actual effects.

Event

An immutable record of what happened.

Projection

A derived read model of workflow state, run history, artifacts, approvals, and outcomes.

⸻

First Intent Types

Current starts with a deliberately small algebra of effects.

Read-only intents
	•	read_file
	•	glob
	•	grep
	•	git_diff
	•	git_log

Mutating intents
	•	file_patch
	•	write_file
	•	delete_file

Execution intents
	•	run_command
	•	run_test
	•	run_formatter

Control intents
	•	request_approval
	•	reject_step
	•	retry_step
	•	handoff

Reporting intents
	•	report
	•	claim
	•	artifact

Each intent is validated before interpretation.

⸻

Event Model

Example events:
	•	TaskSubmitted
	•	StepScheduled
	•	StepStarted
	•	IntentProposed
	•	IntentValidated
	•	IntentRejected
	•	EffectApplied
	•	EffectFailed
	•	ClaimVerified
	•	StepCompleted
	•	PipelineCompleted

All durable state is derived from these events.

⸻

Why Event Sourcing?

Event sourcing gives Current several important properties:
	•	full audit trail
	•	deterministic replay
	•	easy debugging
	•	time-travel inspection
	•	reproducible projections
	•	approval history
	•	clean separation between command and read models

For AI workflows, this matters because it lets us inspect not just the final result, but the exact chain of decisions and validations that led there.

⸻

Safety Model

Current is designed around defense in depth:
	1.	Agents cannot perform effects directly
	2.	All intents are schema-validated
	3.	Policies decide what may be interpreted
	4.	Interpreters run in controlled environments
	5.	Every transition is recorded

This does not make LLMs deterministic or correct.

It does reduce blast radius and make failures observable.

⸻

Determinism

Current does not make model output deterministic.

It does make the surrounding system more deterministic:
	•	workflow scheduling
	•	schema validation
	•	policy checks
	•	intent interpretation
	•	event recording
	•	state projection

The model may vary.
The runtime should not.

⸻

Use Cases

Current is a good fit for:
	•	code generation with approval gates
	•	large repo maintenance
	•	refactoring pipelines
	•	documentation generation
	•	migration planning
	•	CI-assist workflows
	•	security review flows
	•	“plan first, apply later” agent systems

It is especially useful where auditability matters.

⸻

Non-Goals

Current is not trying to be:
	•	a general chat interface
	•	an autonomous shell robot
	•	a replacement for CI/CD
	•	a magical correctness engine
	•	a framework for unconstrained agent swarms

It is a runtime for bounded, inspectable, typed AI workflows.

⸻

Why Pure Functional?

Because pure systems make good boundaries.

A pure core gives us:
	•	testable reducers
	•	replayable state
	•	explicit effects
	•	easier reasoning
	•	fewer hidden mutations

Current borrows from:
	•	event sourcing
	•	CQRS
	•	typed effect systems
	•	workflow engines
	•	functional architecture
	•	actor-style orchestration

⸻

Roadmap

Phase 1
	•	workflow definition format
	•	intent schema
	•	append-only event log
	•	validator
	•	local file/command interpreter
	•	CLI for plan / simulate / apply

Phase 2
	•	approval policies
	•	sandbox workspaces
	•	artifact browser
	•	replay and time-travel inspection
	•	branch/worktree support

Phase 3
	•	distributed interpreters
	•	typed contracts between steps
	•	richer projections
	•	supervised long-running workflows
	•	plugin adapter system

Phase 4
	•	BEAM-native runtime
	•	process-per-step orchestration
	•	durable mailbox/event bridge
	•	fault-tolerant distributed execution

⸻

Status

Current is early.

The initial goal is to prove a simple but powerful loop:
	1.	define workflow
	2.	produce intents
	3.	validate intents
	4.	optionally interpret effects
	5.	record events
	6.	project state
	7.	repeat

If that loop is solid, everything else can grow from it.

⸻

Hello World

Coming soon.

Planned first demo:

current init
current plan "add input validation to signup form"
current simulate run feature/signup-validation
current apply run feature/signup-validation
current events tail


⸻

Inspiration

Current is inspired by the gap between:
	•	powerful agent systems
	•	trustworthy production systems

It takes seriously the idea that AI workflows should be designed more like databases, compilers, and distributed systems — and less like shell scripts with better branding.

⸻

Contributing

Contributions are welcome, especially in:
	•	intent algebra design
	•	event model design
	•	reducer/projection architecture
	•	sandbox interpreters
	•	workflow DSL design
	•	BEAM runtime ideas
	•	test harnesses and replay tooling

⸻

License

MIT

