# Current

**Change control for AI agents**

Users submit requests to Current. Current works with agents over their provider's API (the agent doesn't run on your machine and has no direct access to your system). Agents are limited to generating typed, reviewable proposals. The runtime validates each proposal before handing it to the user (or another agent) for review, approval and application.

All lifecycle events of the workflow are captured in a tamper-evident, hash-chained commit log (write-ahead log), which enables verification and replay.

**The agent proposes. The runtime acts. The record is the source of truth.**

[The Elevator Pitch](#the-elevator-pitch) · [See it in action](#see-it-in-action) ·
[Quickstart](#quickstart) · [How it works](#how-it-works) ·
[Provenance](#provenance-from-a-change-back-to-the-request) ·
[Reproducibility](#reproducibility-replay-the-record-anywhere) ·
[Verifiability](#verifiability-a-hash-chained-history) ·
[Architecture](#architecture) · [Intents](#intents) · [CLI](#cli-reference) ·
[HTTP API](#http-api) · [MCP](#mcp) · [Configuration](#configuration) ·
[Security](#security) · [Status](#what-exists-today) · [Roadmap](#roadmap)

---

## The Elevator Pitch

**Why not just use Claude Code or Codex?** You can. But today the choice is all-or-nothing: give an agent direct access to your files, shell, and network, or don't use agents. Current is a third option.

- **Safety**: The agent is limited to doing just one thing -- *producing proposals*. It sees only the approved project files it asks for, and can only propose changes from nine typed intents. Nothing touches your project until you approve it, and only allowlisted commands can run.
- **Verification**: You don’t take the agent’s word for it. You review the exact proposal, or have other agents review it, before anything happens, and Current checks the agent’s claims against what actually ran.
- **Provenance**: As agents write more of the code, someone will ask *why was this changed, and who approved it?* Current answers from a commit log: the oldest, best-tested idea in systems.

That log is hash-chained, so changes to past history are detectable, and the full state can be rebuilt from it on another machine.

> **Status: early.** Single node, local projects. Current is not a sandbox
> or an authentication system: approved commands run with the runtime's
> privileges. See [Security](#security) and the
> [threat model](docs/threat_model.md).

---

## See it in action

Ask Current to add CSRF protection to the included Next.js example:

```sh
current run "add CSRF protection to this app" \
  --dir examples/nextjs-auth \
  --model openai:gpt-5.6-sol
```

The model never gets the repository. It sees the layout and asks for what
it needs, and Current fetches each file:

```text
… round 1: the model asked to see 8 things
    ✓ read_file app/api/login/route.ts       769 B
    ✓ read_file lib/auth.ts                  626 B
    ✓ read_file lib/rate-limit.ts            2.4 KB
    ✓ read_file tests/login.test.ts          847 B
    ✓ read_file tests/rate-limit.test.ts     2.3 KB
    ✓ read_file package.json                 343 B
    ✓ read_file tsconfig.json                221 B
    ✓ read_file .gitignore                   83 B
```

Reads are confined to the project. Dependencies, build output, `.git` and
`.env*` files are never shown to the model, and every read is recorded.

Then it returns a proposal:

```text
Agent produced proposal
  proposal sha256:672c4973787b…

  The login route already invokes a missing CSRF validator before parsing
  credentials. Implement that validator with fail-closed same-origin Origin
  checking and add focused coverage for accepted and rejected origins.

PROPOSED

   1  WriteFile    lib/csrf.ts
   2  WriteFile    tests/csrf.test.ts
   3  RunCommand   npm test
   4  Report       Add fail-closed same-origin CSRF validation for the login
                   route and unit tests covering valid, absent, malformed,
                   and cross-origin headers.

✓ Proposal decoded
✓ Proposal validated

Waiting for approval. Nothing has been applied.
```

**The agent has proposed a change. Your project is untouched.**

Review the exact files and commands, or pass the machine-readable version
(`--json`) to another agent for a second opinion:

```sh
current review sha256:672c4973787b
```

Then decide. Send it back with feedback, and the model reads more and
returns a new proposal:

```sh
current revise sha256:672c4973787b -m "add a test for a missing Origin header"
```

Or approve it. Approval is recorded, but nothing runs yet:

```sh
current approve sha256:672c4973787b -m "LGTM"
```

```text
✓ Approved sha256:672c4973787b
  message  LGTM

Nothing has been applied. Apply it with:
  current apply sha256:672c4973787b
```

Applying is its own step. Current, not the agent, writes the files and
runs the command:

```sh
current apply sha256:672c4973787b
```

```text
✓ Proposal approved
✓ Workflow completed

MODE: APPLY
4 effects executed.

Inspect
  current events   sha256:1429719b7546
  current proposal sha256:672c4973787b
  current artifact sha256:fb30687f1722   (raw model output)
```

Every step above, from the request and each file the model read to its raw
reply, the approval and each effect's output, is now part of the workflow's
record. `current events` prints it.

---

## Quickstart

### Requirements

- Elixir 1.19 on Erlang/OTP (`mise.toml` pins OTP 28.5 and Elixir 1.19.5;
  run `mise install` if you use [mise](https://mise.jdx.dev/))
- `git`, `make`, and `bash`
- An OpenAI or Anthropic API key

### 1. Get the code and build

```sh
git clone https://github.com/santosh79/current.git
cd current
mix deps.get
mix compile
make client
```

### 2. Start the runtime

In one terminal, export a key and start the server. It listens on
`127.0.0.1:4000` and prints every request and commit as it happens.

```sh
export ANTHROPIC_API_KEY="..."     # or OPENAI_API_KEY
export CURRENT_ALLOWED_COMMANDS=npm  # commands are denied unless allowlisted
bin/current-server
```

### 3. Make a request

In another terminal, from the repository root:

```sh
export PATH="$PWD:$PATH"   # puts the local `current` CLI on PATH
current models             # the models your keys give you

current run "add CSRF protection to this app" \
  --dir examples/nextjs-auth \
  --model <a-model-from-current-models>
```

`run` stops when the proposal is waiting for review. Output varies between
models and runs. Use `plan` instead of `run` for a proposal that can be
reviewed but never applied.

### 4. Review, decide, apply

```sh
current review  <proposal-id>
current revise  <proposal-id> -m "keep the route check, add edge cases"
current approve <proposal-id> -m "reviewed"
current apply   <proposal-id>
```

Or `current reject <proposal-id> -m "..."` to end the workflow. A revision
produces a new proposal ID, which must be reviewed and approved in turn;
the earlier one is stale. IDs can be shortened to a unique prefix of at
least four hex characters.

### 5. Trace it

```sh
current events   <workflow-id>   # the full chain, in log order
current proposal <proposal-id>   # intents, claims, and what the model read
current artifact <artifact-id>   # exact bytes: a file, command output, a raw reply
```

---

## How it works

In a typical agent, a tool call *is* the action: the file is written the
moment the model decides to write it. In Current, the model's output is a
**proposal**, a list of typed intents:

> "in `lib/signup.ex`, replace this text with that"; "run `mix test`";
> "claim the tests pass, because that command exits 0"

A proposal does nothing on its own. Between it and your project, the
runtime:

1. **decodes** the model's reply, which is untrusted bytes, into a closed
   set of intent types. Anything outside it is rejected, not interpreted;
2. **validates** it: paths confined to the project, files exist, every
   edit matches exactly, claims cite earlier intents they can be checked
   against;
3. **waits for a decision.** A proposal is reviewed as a unit and approved,
   rejected, or sent back with feedback. The reviewer can be a person or
   another agent: each decision is an API call, recorded as its own event
   with the reviewer's metadata. A decision must name the workflow's latest
   proposal, and revisions are bounded (10 by default);
4. **applies** it, in a separate step, with a small trusted interpreter
   that re-checks every path immediately before touching it and records
   every result;
5. **checks the outcome itself.** Claims are evaluated against recorded
   results, and a claim that doesn't hold fails the workflow.

```mermaid
flowchart TD
    task["Request: prompt, project, model"] --> layout["Model sees the project layout"]
    layout --> reply{"Model replies"}
    reply -- "observe" --> read["Runtime reads files<br/>(read-only, filtered, recorded)"]
    read -- "up to 8 rounds" --> reply
    reply -- "proposal" --> recorded[("Decoded and recorded")]
    recorded --> validate{"Validate"}
    validate -- "invalid" --> failed1(["failed"])
    validate -- "plan mode" --> planned(["planned"])
    validate -- "apply mode" --> review{"Review<br/>(person or agent)"}
    review -- "revise (feedback)" --> revision["Revision requested"]
    revision -- "new proposal, up to 10 times" --> reply
    review -- "reject" --> rejected(["rejected"])
    review -- "approve, then apply" --> apply["Runtime applies intents in order"]
    apply --> verify{"Claims hold?"}
    verify -- "yes" --> completed(["completed"])
    apply -- "effect fails" --> failed2(["failed"])
    verify -- "no" --> failed2
```

Every step is an event. Rounded boxes are where a workflow ends.

### Producing a proposal

1. A **task** is submitted with a prompt, a project directory and a model.
   The directory is resolved once to its real path and recorded.
2. The model is given the project's **layout**: paths and sizes, no
   contents. Dependencies, build output, VCS directories and `.env*` files
   are left out.
3. The model may reply with an **observe** request: up to 20 `read_file`,
   `glob` or `grep` intents, each with a reason. The runtime runs them
   read-only, under path confinement and the read policy, and asks again
   with the results. Up to 8 rounds, 400 KB of results in total, 200 KB
   per file.
4. The model replies with a **proposal**. Its exact reply is stored as an
   artifact, whatever it contains.
5. The proposal is **decoded** into typed intents
   ([wire contract](docs/wire_schema.md)), every path is made absolute
   against the project, and it is **validated**.

Validation answers "is this well-formed and in bounds right now?", not
"will it apply cleanly?". The project can change before apply, and those
failures are caught and recorded then. Producing a proposal is bounded by
`llm_proposal_timeout_ms` per call and the task's `--timeout-minutes`
(default 10) overall.

### Applying it

`apply` starts the interpreter. It re-checks every path against the
filesystem as it is *now* (following symlinks), then carries out the
intents in order. The first failure, or the first claim that doesn't
hold, stops it and fails the workflow. Effects are not rolled back. The
re-check narrows the window for a path to escape the project but doesn't
close it (T2 in the [threat model](docs/threat_model.md)).

### Lifecycle

```text
created → planning → validating → waiting_for_approval
   plan mode:   → planned
   apply mode:  → approved → applying → assembling_result → completed
                → rejected
                → revision_requested → planning → validating → waiting_for_approval
                  (bounded; each pass adds a proposal to the workflow)
any stage:      → failed      (production, validation or an effect failed)
                → abandoned   (no further automatic progress is possible)
```

### Three primitives

| Primitive | When | Role | More |
|---|---|---|---|
| Intent | Before execution | A proposal, as data | [intent.md](docs/intent.md) |
| Event | After execution or decision | A fact | [event.md](docs/event.md) |
| Artifact | Throughout | Immutable bytes, named by their SHA-256 | [artifact.md](docs/artifact.md) |

> *Intents propose change. Artifacts hold bytes. Events record fact.
> State is derived from the event log.*

---

## Provenance: from a change back to the request

Because the runtime is the only thing that acts, and records each step
before taking the next, every change sits at the end of an explicit chain:

```text
TaskCreated                  the request: prompt, model, project, submitted_at
└─ WorkflowCreated
   └─ ProposalProduced       intents, what the model read first, its raw reply
      └─ ProposalValidated
         ├─ ProposalRevisionRequested   who asked for what change; loops back to
         │  └─ ProposalProductionStarted → ProposalProduced (revision 1, revises
         │     the one above) → ProposalValidated → ... up to the bound
         └─ ProposalApproved     who, when, with what message
            └─ EffectApplicationStarted
               ├─ EffectApplied      an edit: file before and after
               ├─ EffectApplied      a command: exit code, stdout, stderr
               ├─ EffectApplied      a claim: verified, and against what
               └─ WorkflowCompleted
```

So for any change you can answer, from the record alone and without the
model:

| Question | Answered by |
|---|---|
| Who asked for this, and what exactly did they ask? | `TaskCreated`: the prompt, model and project |
| Why does the agent say it's needed? | The proposal's justification and claims |
| What did the model look at before deciding? | Each observation, with its reason and the exact bytes it was shown |
| What did the model actually say? | Its raw reply, stored byte for byte |
| Who authorized it, and when? | `ProposalApproved` and its metadata |
| What did the reviewer ask to change, and what came of it? | `ProposalRevisionRequested` and the next proposal's `revision` and `revises` |
| What exactly changed? | Each effect's result: file before and after, command output |
| Did it do what the agent claimed? | Each claim's verification and evidence |
| What *didn't* happen, and why? | Rejections, validation failures, failed effects, each with a reason |

**Authorization is recorded, not enforced by identity.** Current
guarantees that nothing is applied without an approval event in the chain,
followed by a separate apply, and the reducer enforces that at commit
time. Who may approve is for a layer in front of it: approvals enter
through one route (`POST /v1/proposals/:id/approve`), where a gateway can
authenticate the caller and write verified identity into the approval's
metadata. Today `reviewed_by` is whatever the client sends.

---

## Reproducibility: replay the record anywhere

The commit log and the artifact store are the whole of Current's state.
Nothing else is persisted, and everything the runtime shows you (tasks,
proposals, workflows) is rebuilt from them. So the record is portable:
copy the data directory to another machine, and replaying it gives the
same history.

There are two levels of replay, and it matters which one you mean.

**Replaying the record (works today).** Every workflow state is a pure
function of its events (see [the reducer](#the-reducer)). Every piece of
content those events refer to is an immutable artifact named by its
SHA-256. Replaying the same log, anywhere, gives the same states, the
same accepted transitions and the same rejections, and every artifact
can be checked against its own name. Point `CURRENT_DATA_DIR` at a copy
and the runtime rebuilds it on start. (Starting the runtime also resumes
or fails workflows that were still in progress, which appends new
events. Copy a record whose workflows have finished.)

**Re-executing the proposals (planned).** This is the stronger check:
take the approved proposals, apply them to the same starting tree on
another machine, and compare. Current records what makes that
comparison exact. Each edit stores the file's before and after content
hashes, and each command stores its exit code and output, so a re-run can
be diffed against the original byte for byte. Edits replay
deterministically. Commands are as reproducible as the environment
they run in, and a difference shows up as a different artifact hash. A
`current export` / `current replay` pair to do this is on the
[roadmap](#roadmap).

---

## Verifiability: a hash-chained history

The commit log is a hash chain, the structure blockchains use to make
history tamper-evident (without mining, tokens or multi-party consensus).

```text
commit 1              commit 2                commit 3
┌────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ index: 1       │    │ index: 2         │    │ index: 3         │
│ previous: nil  │◀───│ previous: H(c1)  │◀───│ previous: H(c2)  │◀── head
│ events: [...]  │    │ events: [...]    │    │ events: [...]    │
└────────────────┘    └──────────────────┘    └──────────────────┘
                 H(c) = SHA-256 of term_to_binary(commit, [:deterministic])
```

Changing any byte of any past commit changes its hash and breaks every
link after it, so **the head hash fingerprints the entire history**. It
also covers the content: events refer to file contents, edits, command
output and model replies by their SHA-256 artifact ids, so those are
committed to as well.

- **Only valid successors are written.** A commit must have the next index
  and the head's hash as `previous_hash`, or it is refused and nothing is
  written.
- **Durable before acknowledged.** A commit is fsynced before anyone hears
  of it.
- **Verified on every start.** Every link is re-checked, across segments.
  A gap, a broken link or corrupt bytes stop the runtime from starting,
  naming the file. It refuses to serve a history it can't vouch for.
- **Closed segments are immutable**, and opened read-only.

Commit hashes currently use `:erlang.term_to_binary/2` with the
`:deterministic` option. This makes term encoding deterministic within the
supported Erlang term format, but does not guarantee byte-for-byte identical
encoding across OTP versions. Cross-version verification needs a stable,
versioned canonical encoding (see the [roadmap](#roadmap)).

**What this proves today:** integrity. The history the runtime replays is
exactly the history it wrote, unbroken and in order. **What it doesn't
yet:** authenticity to an outsider. Commits aren't signed, so someone
who can write the data directory can rewrite history and recompute every
hash. Signing the head, or publishing it somewhere the writer can't reach,
closes that gap: once a third party holds a head hash, every request,
approval and effect beneath it is verifiable against it. That, and
re-verifying artifact hashes on read, are on the [roadmap](#roadmap).

---

## Architecture

Current applies functional-programming and distributed-systems patterns
to agent workflows. Each provides one of the properties above.

| Pattern | In Current | Gives you |
|---|---|---|
| **Event sourcing** | Every step is a typed, past-tense, versioned event. The log is the only source of truth | Provenance, replay |
| **CQRS** | Commands (`submit`, `approve`, `revise`, `apply`) go through `Current.API` and become proposed events. Queries read projections (`WorkflowStore`, `ProposalStore`, `TaskStore`) built from committed events | Reads never mutate; writes are only events |
| **Pure reducer** | `WorkflowReducer.apply_event/2`: state × event → state, or refusal | Deterministic state; one definition of what is allowed |
| **Immutability** | Events are never edited or deleted; corrections are new events. Artifacts never change | A history worth verifying |
| **Content addressing** | Artifacts are named by the SHA-256 of their bytes | Deduplication, and content that checks itself |
| **Hash-chained WAL** | Each commit carries the previous commit's hash | Tamper evidence |
| **Interpreter pattern** | Intents are data in a closed algebra; `EffectApplicator` is the one module that interprets them against the world | The agent can't act; a minimal trusted surface |
| **Pure core, impure edge** | Model calls and effects run at the edge and come back as events | Effects are captured, not hidden |
| **Schema evolution by upcasting** | Old events are migrated on read by pure, versioned functions, never rewritten on disk | Old logs keep replaying through new code |
| **Consensus interface** | Commits are ordered through `Current.Consensus.propose/1`; single-node today | A path to a replicated log |

### The reducer

At the center is one pure function:

```elixir
WorkflowReducer.apply_event(workflow | nil, event)
  :: {:ok, workflow} | {:error, {:invalid_transition, status, event_type}}

WorkflowReducer.replay(events)   # a fold of apply_event over the log
```

It reads no clock, touches no disk and calls no model. Every timestamp
comes from the event. It *is* the workflow state machine, an explicit
table of `(status, event) → status` clauses, and anything not in the
table is refused:

| Rule | Enforced by |
|---|---|
| Nothing applies without approval | `EffectApplicationStarted` is accepted only from `:approved` |
| A plan can never be applied | `ProposalApproved` is accepted only for `mode: :apply` |
| One decision per proposal | approval, rejection and a revision request are accepted only from `:waiting_for_approval` |
| Only the latest proposal can be decided | approval, rejection, a revision request and `EffectApplicationStarted` must name the workflow's most recent proposal, else `{:stale_proposal, given, current}` |
| Revisions are bounded | a revision request is refused with `{:revision_limit_reached, max}` once `max_revisions` (recorded on `WorkflowCreated`, default 10) are used |
| Terminal means terminal | nothing moves a `completed`, `planned`, `rejected`, `failed` or `abandoned` workflow |

The same function is used at every layer, so the layers can't disagree.
`EventStore` replays a workflow's events plus each new one **at commit
time**, so an event the reducer refuses never becomes canonical, and of
two racing approvals only one is accepted. The API runs it as an early
check before proposing. The projections are the reducer applied to the
stream, and recovery replays through it on restart. Because acceptance
is itself a pure function of the events already accepted, replaying the
log reproduces every rejection as well as every state.

### The orchestrator is a policy, not a script

`WorkflowOrchestrator` maps each committed event to the next event it
proposes (`WorkflowCreated → ProposalProductionStarted`, `ProposalProduced
→ ProposalValidated | ProposalValidationFailed`, ...). It never changes
state directly, and acts only on what is committed. Model calls and effects
run in separate processes, and their results come back as messages that
become events. Nothing an effect does counts until it is an event.

### Never guess after a crash

On restart, every workflow is rebuilt from the log and resumed from what
the log says. A workflow interrupted mid-apply is failed rather than
resumed, because an effect that may already have happened is never
repeated. One that crash-loops is retried with backoff, then abandoned on
the record.

---

## Intents

| Intent | What it does when applied | Allowed in `observe` |
|---|---|---|
| `read_file` | Reads a file and stores its contents | yes |
| `glob` | Lists files matching a relative pattern | yes |
| `grep` | Finds lines containing a literal string in listed files | yes |
| `write_file` | Creates a new file; fails if it already exists | |
| `edit_file` | Replaces exact text (`old_string` → `new_string`); must match once unless `replace_all`; stores before and after | |
| `delete_file` | Deletes a file; stores its contents first | |
| `run_command` | Runs an executable with arguments in the project; stores stdout, stderr and exit code | |
| `claim` | Checks a statement against an earlier intent's result (`exit_code_equals`, `match_count_equals`, `match_count_greater_than`) | |
| `report` | A summary for the reader; no effect | |

---

## CLI reference

| Command | What it does |
|---|---|
| `current run <prompt> --model <m> [--dir <d>] [--timeout-minutes <n>]` | Make a request; stops when the proposal waits for review. |
| `current plan <prompt> --model <m> [--dir <d>] [--timeout-minutes <n>]` | Produce and validate a proposal that can never be applied. |
| `current review <proposal-id> [--json] [--max-lines <n>] [--raw]` | A proposal with its edits, files and commands. `--json` emits `current.review/v1`. |
| `current approve <proposal-id> [-m <message>]` | Record approval. Nothing is applied. |
| `current reject <proposal-id> [-m <message>]` | Turn a proposal down; the workflow ends. |
| `current revise <proposal-id> -m <feedback>` | Send a proposal back. The agent produces a replacement; follows the workflow until it waits for review again. Must name the latest proposal. |
| `current apply <proposal-id>` | Apply an approved proposal, verify its claims, follow it to the end. |
| `current events <workflow-or-task-id>` | The chain: a workflow's events, in log order. |
| `current proposal <proposal-id>` | A proposal in full: intents, claims, observations, artifacts. |
| `current artifact <artifact-id>` | An artifact's exact bytes, for piping. |
| `current models` | Models discovered from the configured providers. |
| `current status` | Whether the runtime is up, and how it is configured. |

`--model` is required; use a name `current models` prints.
`--timeout-minutes` is 1 to 60. The CLI holds no state: interrupt it at any
point and the workflow carries on in the runtime. Exit codes are 0 on the
expected outcome, 1 on failure and 2 on a usage error.

---

## HTTP API

The CLI does nothing a script, or another agent, can't: it calls these
routes.

| Route | Does |
|---|---|
| `POST /v1/tasks` | Submit a task: `{"prompt", "model", "dir", "mode", "timeout_ms"}` → `202 {"task_id"}` |
| `GET /v1/workflows/:id` | A workflow's status and events (a task id or unique prefix works) |
| `GET /v1/workflows/:id/activity` | What the model has asked to see so far (`?epoch=&after_seq=`) |
| `GET /v1/proposals/:id` | A proposal in full |
| `GET /v1/proposals/:id/review` | The `current.review/v1` document (`?max_lines=&raw=true`) |
| `POST /v1/proposals/:id/approve` | Record approval: `{"message", "reviewed_by"}` |
| `POST /v1/proposals/:id/reject` | Turn the proposal down |
| `POST /v1/proposals/:id/revise` | Send it back: `{"feedback", "reviewed_by"}`. `409 stale_proposal` if a newer proposal exists (`details.current_proposal_id`); `409 revision_limit_reached` when none are left |
| `POST /v1/proposals/:id/apply` | Start applying an approved proposal |
| `GET /v1/artifacts/:id` | An artifact's exact bytes |
| `GET /v1/models`, `GET /v1/health` | The model catalog; whether the runtime is up |

Errors are `{"error": {"code", "message"}}` with a matching status. The
API does no authentication (see [Security](#security)). Every route checks
`Host` and, when present, `Origin` before reading the body. Loopback Host
values must use the configured runtime port; deployments behind another
hostname must add its exact authority to `http[:allowed_hosts]`.

---

## MCP

Current also exposes a Model Context Protocol (MCP) server at `POST /mcp`,
using Streamable HTTP and protocol version `2025-06-18`. It exposes tools
for submitting tasks, inspecting workflows and proposals, reviewing and
retrieving artifacts, approving, rejecting, requesting revisions, applying
proposals, listing models, and checking runtime health.

The MCP endpoint uses the same `Current.API` and runtime invariants as the
CLI and HTTP API. Tasks return immediately with a task id; clients poll
`get_workflow` for progress. It is stateless and tools-only: no sessions,
resources, prompts, server-initiated streams, or batch requests. `GET /mcp`
is not supported.

**MCP does not authenticate callers.** Anyone who can reach the endpoint can
submit, approve, and apply proposals. Keep it on loopback or behind a trusted
gateway that enforces access control. Like every route, it checks `Host` and
`Origin`; it additionally checks `MCP-Protocol-Version` and `Content-Type`.
These are not substitutes for authentication. See [Security](#security) and the
[threat model](docs/threat_model.md).

---

## Configuration

### Environment

| Variable | Read by | Meaning |
|---|---|---|
| `OPENAI_API_KEY` | runtime | Enables `openai:*` models |
| `ANTHROPIC_API_KEY` | runtime | Enables `anthropic:*` models |
| `CURRENT_DATA_DIR` | runtime (prod) | Where the log and artifacts live (default `./_data`) |
| `CURRENT_ALLOWED_COMMANDS` | runtime (prod) | Comma-separated exact `cmd` values allowed for `run_command`; unset keeps the configured default |
| `CURRENT_HTTP_PORT` | runtime | Port of the HTTP API (default `4000`) |
| `CURRENT_HTTP_IP` | runtime | Address the HTTP API binds (default `127.0.0.1`) |
| `CURRENT_URL` | CLI | Where the CLI finds the runtime (default `http://127.0.0.1:4000`) |

The runtime starts without an API key, but its model catalog is empty until
one is set.

### Application config (`config/*.exs`)

| Key | Default | Meaning |
|---|---|---|
| `data_dir` | `"./_data"` | Log in `consensus/`, artifacts in `artifacts/` |
| `allowed_commands` | `[]` | Executables `run_command` may run; empty denies all. The configured list is included in the model prompt. Not a sandbox |
| `llm_proposal_timeout_ms` | `240_000` | Bound on one model call |
| `llm_task_timeout_ms` | `600_000` | Default bound on producing one proposal |
| `commit_log_segment_bytes` | 64 MiB | Log segment size before rolling over |
| `proposal_builder` | `Current.LLMProposalBuilder` | What produces proposals |
| `effect_applicator` | `Current.EffectApplicator` | What applies intents |
| `http[:allowed_hosts]` | `[]` | Exact Host authorities allowed in addition to loopback hosts on the configured port, for example `current.internal:443` |
| `mcp[:allowed_origins]` | `[]` | Exact browser origins allowed on every route in addition to loopback origins |
| `mcp[:allow_loopback_origins]` | `true` | Whether browser origins on `localhost`, `127.0.0.1`, and `[::1]` are accepted |
| `model_catalog_clients` | OpenAI, Anthropic | Providers asked for models |

---

## Security

Current controls *when* an agent's proposal takes effect and records
everything about it. It does not limit *what* an approved proposal can do.

- **Nothing an agent proposes runs without approval** and a separate
  `apply`, enforced by the reducer at commit time.
- **Paths are confined** to the project, checked lexically at validation
  and again, following symlinks, just before each effect.
- **What the model sees is filtered** by name (dependencies, build output,
  VCS directories, `.env*`). Other secrets in the project are *not*
  recognised.
- **`run_command` is restricted by an exact executable allowlist, not sandboxed.**
  Commands are denied by default. The proposal's `cmd` must exactly match a
  configured entry; a bare name is resolved on `PATH`, while a relative path
  containing `/` is resolved from the project. Allowed commands run through a
  Bash wrapper in the project directory with the runtime's privileges and
  inherited environment, including filesystem and network access. Arguments
  are unrestricted, so allowing interpreters, shells, package managers, or
  script-dispatching executables can permit arbitrary code execution. There is
  currently no command timeout, output-size cap, environment allowlist, or
  explicit descendant-process cleanup. Output is captured in unbounded
  temporary files until the command exits.
- **The HTTP API is unauthenticated.** It listens on 127.0.0.1. Every route
  validates `Host` and browser `Origin` to prevent DNS rebinding, but these
  checks do not authenticate non-browser clients. Restrict who can reach it
  with a gateway, proxy or network policy; anyone who can reach it can
  approve and apply.
- **The log is tamper-evident to the runtime, not yet to an attacker.**
  See [Verifiability](#verifiability-a-hash-chained-history).

Full analysis: [docs/threat_model.md](docs/threat_model.md). Please report
vulnerabilities privately.

---

## What exists today

| | Status |
|---|---|
| Request, review, approve, reject, apply from the CLI or HTTP | ✅ |
| Bounded revision loop: a reviewer sends a proposal back with feedback | ✅ |
| Request, proposal, approval and effects linked in one log | ✅ |
| What the model read, and its raw replies, recorded with the proposal | ✅ |
| Verified claims: a false claim fails the workflow | ✅ |
| Pure reducer enforcing every transition at commit time | ✅ |
| Hash-chained, segmented WAL, verified on every start | ✅ |
| State and rejections rebuilt deterministically from the log | ✅ |
| Content-addressed artifacts for every input and output | ✅ |
| Versioned events with upcasting | ✅ |
| OpenAI and Anthropic models, chosen per task | ✅ |
| MCP tools over stateless Streamable HTTP (`POST /mcp`) | ✅ |
| Command executable allowlist (deny by default) | ✅ |
| `current export` / `current replay`: re-execute on another machine and diff | planned |
| `current verify`: check the chain and every artifact, print the head hash | planned |
| Signed or externally anchored log heads | planned |
| Approval policy hook / authenticated approvers | planned (layered on top) |
| Command timeout, output cap, environment filtering, and process-tree cleanup | planned |
| Atomic apply, `simulate` | planned |

---

## Roadmap

**Next**

- `current export` and `current replay`: bundle a workflow's events and
  artifacts, re-apply on another machine against the same starting tree,
  and diff every artifact hash
- `current verify`: re-check the chain and every artifact against its
  name, and print the head hash
- an approval policy hook (N approvers, an approver other than the
  requester), where an ACL layer plugs in
- command timeout, output cap, environment filtering, and process-tree cleanup
- atomic apply, and `simulate` in a throwaway copy

**Later**

- signed log heads, and publishing head hashes externally
- a stable, versioned canonical encoding for commit hashes (today they use
  `:erlang.term_to_binary([:deterministic])`, which does not guarantee
  identical bytes across OTP versions)
- log snapshots, so startup doesn't replay everything
- sandboxed interpreters
- a replicated log behind the existing consensus interface

---

## Contributing

Contributions are welcome, especially in:

- replay, export and verification tooling
- approval policy and access control on top of the approval record
- interpreters and sandboxing
- the intent algebra and wire contract
- event model, reducers and projections

`mix test` runs the suite. If your change alters what an event stores,
bump the event's version and add an `upcast` clause; recorded logs must
keep loading.

---

## License

MIT

