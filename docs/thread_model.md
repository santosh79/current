# Threat model

This document says what Current protects against, what it does not, and
how to run it more safely. It describes the code as it is, not as it is
planned to be. Where something is planned, it says so.

If you find a way around a mitigation described here, please report it
privately rather than in a public issue.

---

## Summary

Current's promise is narrow, and it keeps it: **Current does not execute
agent-proposed changes without explicit human authorization.** An agent can
only propose, every proposal is recorded, and nothing is applied until a
person approves it and then asks for it to be applied.

That is a promise about *when* things run, not about *what* runs. Once
authorized, a proposal can do anything its intents allow, and a
`run_command` can do anything the runtime's user can.

What Current does **not** promise:

- **It is not a sandbox.** An approved `run_command` runs as the runtime's
  user, with that user's environment (including API keys), filesystem and
  network. Approving any command, including `mix test` or `npm test`,
  approves running arbitrary code.
- **It does not make approval safe.** It makes it informed. A malicious or
  mistaken proposal that a person approves will be carried out.
- **It does not authenticate users.** Anyone who can reach the runtime's
  Erlang node with its cookie has full control of the runtime, not just the
  CLI's commands.
- **It does not keep secrets out of a prompt in general.** It keeps out
  files whose *names* look like dependencies, build output, VCS state or
  `.env*`. A key in `config/prod.secret.exs` or `id_rsa` can be shown to the
  model.

Current is built for one person, on their own machine, working on a project
they contr
ol. Everything below follows from that.

---

## System and trust boundaries

```text
   ┌────────── you ──────────┐
   │  current (CLI escript)  │
   └───────────┬─────────────┘
               │ ① Erlang distribution (cookie)
   ┌───────────▼──────────────────────────────────────────────┐
   │  runtime node (bin/current-server), runs as one OS user  │
   │                                                          │
   │  RPC ─▶ submit / review / apply                          │
   │  LLMProposalBuilder ─② HTTPS─▶ OpenAI / Anthropic        │
   │     └─ Observer ─③ read-only─▶ project dir               │
   │  Decoder ─▶ Validator ─▶ log                             │
   │  EffectApplicator ─④ writes, patch, commands─▶ project   │
   │  Log + artifacts ─⑤─▶ data dir (_data/)                  │
   └──────────────────────────────────────────────────────────┘
               ④ commands also reach: the OS, the network,
                 everything the user can read
```

| # | Boundary | What crosses it | Trusted side |
|---|---|---|---|
| ① | CLI ↔ runtime | Tasks, approvals, applies, queries | Neither: the cookie is the only check |
| ② | Runtime ↔ model provider | Prompts (project layout, files the model asked for), replies | Runtime. The reply is untrusted input |
| ③ | Runtime ↔ project, while observing | Reads chosen by the model | Runtime, which decides what may be read |
| ④ | Runtime ↔ project and OS, while applying | Writes, patches, deletes, commands | Runtime, after a person approves |
| ⑤ | Runtime ↔ data dir | Log segments, artifacts | Whoever can write the directory |

---

## Assets

| Asset | Why it matters |
|---|---|
| The project directory | The thing being changed. Its integrity is the point |
| Everything else the runtime's user can reach | Home directory, SSH keys, other repos, cloud credentials. Reachable by commands |
| API keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) | Spend money; in the runtime's environment |
| The Erlang cookie | Full control of the runtime |
| Secrets inside the project | Can reach the provider (via observe) or the data dir (via read results and command output) |
| The data dir (`_data/`) | The record. Also holds copies of everything read, deleted, patched or printed |
| The reviewer's attention | The last line of defence. Can be exhausted or misled |

---

## Adversaries

**A1. A mistaken model.** The common case. Proposes the wrong patch, a
destructive command, or a claim that isn't true.

**A2. A model steered by content it reads** (prompt injection). The model
reads files in the project: source, docs, test fixtures, vendored code,
issue text pasted into a task. Any of it can contain instructions. In
effect, *anyone who can put text into the project, or into the prompt, can
write the proposal.*

**A3. Another user or process on the same host.** May be able to read the
data dir, the cookie, or reach the Erlang node.

**A4. Someone on the network.** May be able to reach the Erlang
distribution port if it listens beyond localhost.

**A5. The model provider.** Sees every prompt. Out of scope as an attacker,
but in scope for what you send it.

---

## Assumptions

- The machine, the OS user running the runtime, and the Elixir/Erlang
  installation are not compromised.
- Only you can write the data dir and read the cookie.
- The Erlang node is reachable only from this machine (see
  [Running Current more safely](#running-current-more-safely); this is not
  enforced by Current).
- The person approving a proposal reads it first, with `current review`.

---

## Threats

Each entry: what could happen, what Current does about it today, and what
remains. **Status** is one of *mitigated*, *partly mitigated* or *open*.

### T1. The agent acts without approval

The model's output is text. It is parsed by `ProposalDecoder` into typed
intents and validated. Nothing in that path performs an effect, except
storing the reply and any inline diffs as artifacts. Effects happen only in
`EffectApplicator`, and only after `ProposalApproved` and then
`EffectApplicationStarted` are committed. Plan-mode proposals can never be
approved or applied; the reducer refuses it at commit time, not just in the
CLI.

During *observe*, the model can cause reads: only `read_file`, `glob` and
`grep`, at most 20 per reply and 8 replies per task, through the same path
checks as applied intents plus the read policy.

**Status: mitigated.**

### T2. A path escapes the project

The model writes `../../.ssh/authorized_keys`, an absolute path, or a path
through a symlink that points outside.

- The project directory is resolved once to its real path when the task is
  submitted, and recorded. A directory containing `..` is refused.
- Every path the model names is made absolute against it before the
  proposal is recorded, so the reviewer sees the real target.
- `IntentValidator` rejects any path outside the project, lexically.
- `EffectApplicator` checks again immediately before each effect, following
  every symlink that exists at that moment, and refuses on any escape. Glob
  results that resolve outside the project are dropped.

Remaining:

- **A race between check and use.** The check and the write are separate
  system calls. Something that can change the project directory in between
  (a concurrent process, or a command earlier in the same proposal) could
  swap a component for a symlink. Writes use ordinary `File.write/2`, which
  follows symlinks. `patch` is run on the checked path, and when a hunk
  fails it writes a `.rej` file beside it.
- **Commands are not path-checked at all** (see T3).

**Status: mitigated for file intents, apart from the race.**
Recommended: open files relative to a held directory handle, or apply in a
private copy (see the planned atomic apply), and refuse symlinks at write
time.

### T3. An approved proposal runs harmful code

This is the largest risk, and approval is the only control.

- `run_command` runs any executable on `PATH`, or any path relative to the
  project, with any arguments. Arguments are passed without shell
  interpretation (the runtime uses `bash` only to redirect output), but
  nothing stops a proposal from running `bash` with `-c`.
- A proposal can `write_file` a script and then `run_command` it.
- A proposal can `file_patch` something another tool executes:
  `mix.exs`, `package.json` scripts, a `Makefile`, CI configuration, or a
  Git hook under `.git/hooks/`. The read policy hides `.git` from the model,
  but nothing stops a proposal from *writing* there.
- An innocent-looking command runs project code: `mix test` executes every
  test and compiles every dependency.
- Commands inherit the runtime's environment, so they can read
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and anything else exported to the
  server. They run with full network access, and can read the Erlang cookie
  in `~/.erlang.cookie` and anything else the user can.

Today: every intent, with its full diff, file contents, command and
arguments, is recorded and shown by `current review` before approval.
Approval and application are separate steps.

**Status: open.** This is inherent to running commands without a sandbox.
Recommended, roughly in order of payoff:

1. A command policy: an allowlist of executables (and argument patterns),
   enforced by the validator, so `bash -c` or `curl` is refused before
   anyone is asked.
2. Run commands with a minimal environment (`env: [...]` with only `PATH`,
   `HOME`, `LANG`), so API keys are not inherited.
3. Flag sensitive targets in review: `.git/`, build and CI files, anything
   executable, any command at all.
4. A sandbox for commands: a container or OS-level sandbox with no network
   by default, mounting only the project.

### T4. Secrets are sent to the model provider

The model sees the project's layout (names and sizes), then the contents of
whatever it asks to read, subject to `ReadPolicy`:

- dependency, build, cache and VCS directories (`.git`, `deps`,
  `node_modules`, `_build`, `_data`, ...) are never listed or shown;
- files named `.env*`, lockfiles and crash dumps are never listed or shown;
- these rules apply to the path as written and to the path with symlinks
  followed, so a link named `notes.txt` that points at `.env` is refused.

Remaining:

- **Only names are checked.** `credentials.json`, `*.pem`, `id_rsa`,
  `config/prod.secret.exs`, `secrets.yaml`, or a key pasted into an
  ordinary source file, can all be shown.
- **File names themselves are sent**, for everything not excluded.
- **The prompt itself** is sent as written. Don't paste secrets into a task.

**Status: partly mitigated.** Recommended: a configurable deny list
(`.currentignore`, or honouring `.gitignore`), a larger default list of
secret-looking names, and optionally a content scan for key formats before
a file is shown.

### T5. Secrets leak into the data dir

The data dir holds, as plain files:

- the model's raw replies, and the prompts' inputs it was shown;
- the contents of every file read (by observe or by a `read_file` intent),
  and the before/after of every patched or deleted file;
- the full stdout and stderr of every command.

Note the asymmetry with T4: the read policy governs only what the *model*
is shown. An approved `read_file` of `.env`, or a command that prints the
environment, stores the result in the data dir.

Artifacts are content-addressed and never deleted. File permissions are
whatever the runtime's umask gives. Nothing is encrypted.

**Status: open.** Recommended: create the data dir with mode `0700`;
document it as sensitive; apply the read policy to `read_file` and `grep`
intents in proposals too; add a retention or purge command (events would
keep the artifact id, with the content gone).

### T6. Someone else controls the runtime

The CLI talks to the runtime over Erlang distribution, authenticated only
by the cookie.

- **The cookie is total authority.** Erlang distribution allows any
  connected node to run any code on the runtime: read keys from its
  environment, approve and apply proposals, rewrite memory. `Current.RPC`
  is a convention for clients, not a security boundary.
- **The listener may be reachable from the network.** Unless configured
  otherwise, Erlang distribution listens on all interfaces, and `epmd`
  (port 4369) advertises it. Current does not restrict either.
- **Traffic is not encrypted** unless Erlang distribution over TLS is
  configured.
- **The reviewer's name is not authenticated.** `reviewed_by` on an
  approval is the client's `$USER`, recorded as given.

**Status: open (by design for single-user local use).** Recommended: bind
distribution and `epmd` to localhost (below); a strong random cookie
readable only by you; and, before Current is used by more than one person
or remotely, a real API (HTTP or gRPC) with authentication and per-user
authorization, with Erlang distribution kept internal.

### T7. The record is altered

Each commit records the SHA-256 of the previous one, and the log refuses to
start if indexes or hashes don't line up, naming the bad file. Closed
segments are never repaired; only the active segment may be, after a crash,
and a warning says what was discarded.

This detects **corruption and accidental edits**. It does not detect
**deliberate rewriting**: anyone who can write the data dir can rewrite
history and recompute every hash. Nothing is signed or anchored outside the
machine. Log segments and some artifacts are Erlang terms decoded on load,
so the data dir should be treated as being as trusted as the runtime's code.

Artifacts are named by their hash, but are not re-verified against it when
read.

**Status: partly mitigated.** Recommended: verify artifact hashes on read;
periodically export the head hash somewhere you control (or sign it), so a
rewrite becomes detectable.

### T8. The reviewer is misled

The model writes every word the reviewer reads: the justification, the
report, and each claim's statement.

- **A claim's statement is not what is checked.** Only its evidence
  condition is: "no file outside `src/` changed", backed by a grep that
  found more than zero matches of something unrelated, will verify.
- **Claims are checked during apply, after the effects before them.** A
  false claim fails the workflow, but does not undo anything.
- **Volume.** A large proposal can bury one dangerous intent among many
  harmless ones. Review output is cut to `--max-lines` per artifact by
  default; `current artifact` shows the rest.
- Model-written text is printed to the terminal as is; control characters
  are not stripped.

**Status: partly mitigated.** The review shows the actual intents, diffs
and commands, which are what get applied, not the model's description of
them. Recommended: show commands and sensitive paths first and prominently;
render each claim as "statement / what was actually checked"; strip
terminal control characters from model-written text.

### T9. Apply leaves the project half-changed

Intents are applied in order. The first failure, or the first claim that
doesn't hold, stops the workflow; earlier effects stay. If the runtime stops
while applying, the workflow is failed on restart instead of resumed, so
nothing is applied twice, but the project may be in between.

Before contents of patched and deleted files are kept as artifacts, so they
can be restored by hand.

**Status: partly mitigated.** Recommended: atomic apply (apply to a copy,
promote only if every intent succeeds). Until then: keep the project under
version control, and start from a clean working tree.

### T10. The approved proposal no longer fits the world

Approval can come long after validation. What was approved cannot change:
the proposal and every diff and file it carries are stored immutably,
content-addressed, in the log. But the project can change.

- `file_patch` uses `--fuzz=0`, so a patch fails rather than applies
  somewhere unexpected.
- `write_file` fails if the file now exists.
- Paths are re-checked against the filesystem at apply time (T2).
- Commands are not re-checked: their meaning depends on the state they run
  in.

Two workflows on the same project are not serialised: their applies can
interleave.

**Status: mostly mitigated.** Recommended: record a fingerprint of the
files a proposal touches, and refuse to apply if they changed; a per-project
apply lock.

### T11. Resource exhaustion

- **Commands have no timeout.** A command that never exits leaves its
  workflow in `applying` forever.
- **Command output is unbounded.** It is written to a temporary file, then
  read into memory and stored whole.
- **Proposal production is bounded:** each model call by
  `llm_proposal_timeout_ms` (default 4 minutes), the whole conversation by
  the task's timeout (default 10 minutes, at most 60), 8 rounds of
  observation and 400 KB of results. Anthropic replies are capped at 16,000
  tokens.
- **The log is held in memory and replayed in full on every start.**
  Startup time and memory grow with history.
- There is no limit on concurrent tasks, and so on concurrent spend.

**Status: partly mitigated.** Recommended: a command timeout (kill the
process group) and an output cap first; then log snapshots.

### T12. Talking to the model provider

Requests go to fixed HTTPS endpoints using Erlang's `:httpc`. No TLS
options are passed explicitly, so certificate verification depends on the
OTP version's defaults. **Confirm** that a request to a host with an invalid
certificate fails, and pass `ssl: [verify: :verify_peer, cacerts:
:public_key.cacerts_get()]` explicitly either way.

API keys are read from the environment for each call and sent only in
request headers. Error bodies from the provider may be recorded with a
failed workflow.

**Status: verify.**

---

## Out of scope

- A compromised host, OS user, Erlang/Elixir installation, or dependency of
  Current itself.
- The model provider's own handling of prompts.
- Multiple users sharing one runtime, or remote access. Current has no
  notion of users today (see T6).
- Making a model's proposal *correct*. Current makes it visible and
  checkable.

---

## Running Current more safely

**Isolate the runtime**

- Run it as a dedicated OS user, or in a container or VM, with access to the
  project and little else. This is the only thing that bounds T3 today.
- Export only the API key it needs to that process. Assume any approved
  command can read it.

**Lock down the control plane**

- Keep Erlang distribution on localhost:

  ```sh
  export ERL_EPMD_ADDRESS=127.0.0.1
  export ERL_AFLAGS="-kernel inet_dist_use_interface {127,0,0,1}"
  ```

- Use a long random cookie in a file readable only by you (`chmod 400
  ~/.erlang.cookie`), or set `CURRENT_COOKIE` and the server's cookie
  explicitly.

**Protect the record**

- `chmod 700` the data dir. It contains copies of everything read, deleted,
  patched and printed.
- Back it up if the history matters; it is the only copy.

**Review like it matters**

- Start from a clean, committed working tree, so `git diff` and
  `git checkout` are your undo.
- Read every `run_command` and every change to build files, CI, scripts,
  dependencies and `.git/`.
- Treat "the tests pass" as a claim to check, not a reason to approve.
- Be most careful with projects that contain text you didn't write:
  vendored code, fixtures, issue text, generated docs.

**Don't**

- Point Current at a directory that contains secrets you wouldn't paste
  into a prompt, unless they are in `.env*` files.
- Expose the runtime node to a network.

---

## Mitigations by priority

| Priority | Change | Addresses |
|---|---|---|
| 1 | Explicit TLS verification for provider calls, and a test that a bad certificate is refused | T12 |
| 2 | Command timeout (kill the process group) and output cap | T11 |
| 3 | Minimal environment for commands | T3, T5 |
| 4 | Command allowlist, enforced at validation | T3 |
| 5 | Data dir created `0700`; configurable read deny list; read policy on proposed reads | T4, T5 |
| 6 | Review: commands and sensitive paths first; claims shown with what is checked; control characters stripped | T8 |
| 7 | Atomic apply, and refuse apply if touched files changed | T2, T9, T10 |
| 8 | Authenticated API (HTTP/gRPC) in front of the runtime; distribution kept internal | T6 |
| 9 | Artifact hash verification on read; exported or signed log heads | T7 |
| 10 | Sandboxed command execution | T3 |

---

## Appendix: where each claimed mitigation lives

A threat model is only as good as its claims about the code. Every
mitigation described above as existing today is listed here with the code
that implements it, so it can be checked, and so a change that weakens it
shows up in review. Where a row has no test named, adding one is the
cheapest way to keep the claim true.

| Claim | Where | How to check |
|---|---|---|
| Model output never performs effects; it is only decoded | `Current.ProposalDecoder` (pure apart from `BlobStore.put/1`) | Grep the decoder and `LLMProposalBuilder` for filesystem or `System.cmd` calls |
| Only `:apply` workflows accept approval, from `waiting_for_approval` only | `WorkflowReducer.apply_event_helper/2` (`ProposalApproved` matches `mode: :apply`); `Current.RPC.require_apply_mode/1` | Commit `ProposalApproved` for a plan-mode workflow directly; it must be rejected |
| Apply needs `approved`, and is a separate event | `WorkflowReducer` (`EffectApplicationStarted` only from `:approved`); `Current.apply_proposal/1` | `current apply` before `current approve` fails |
| Project directory resolved once, `..` refused | `Current.submit_task/3` → `validate_project_dir/1`, `canonical_project_dir/1` | Submit with `--dir a/../b` and through a symlink |
| Paths made absolute before the proposal is recorded | `WorkflowOrchestrator` → `IntentPaths.absolutize/2` | `current proposal` shows absolute paths |
| Lexical containment at validation | `IntentValidator.validate_paths/2` → `IntentPaths.violation/2` | Propose `../x` and `/etc/passwd` |
| Containment with symlinks followed, just before each effect | `EffectApplicator.apply/3` → `IntentPaths.resolved_violation/2`, `realpath/1` (40-link limit) | Approve a write, then replace a directory with a symlink to `/tmp` before `apply` |
| Glob matches outside the project dropped | `EffectApplicator.do_apply/3` (Glob) → `resolved_within/2` | Symlinked directory pointing outside |
| Observe: only reads, ≤20 per reply, 8 rounds, 400 KB total, 200 KB per file, 2 MB per grepped file | `Current.Observer` (`@read_only`, `@max_intents_per_round`, `@max_read_bytes`, `@max_grep_file_bytes`); `LLMProposalBuilder` (`@max_observe_rounds`, `@context_budget_bytes`) | Existing tests in `test/e2e/llm_proposal_test.exs` cover rounds and refusals |
| Read policy by name, on the path as written and resolved | `Current.ReadPolicy.violation/2`; used by `Observer` and `ProjectContext` only | A link named `notes.txt` → `.env` must be refused |
| Read policy does **not** apply to proposed intents | `IntentValidator` and `EffectApplicator` never call `ReadPolicy` | A proposal with `read_file .env` validates |
| Commands get no shell interpretation of arguments | `EffectApplicator.run_command_with_redirect/5` (`exec "$1" "${@:4}"`, args passed positionally) | An argument containing `;` or `$(...)` is passed literally |
| Commands inherit the environment, have no timeout | Same function: `System.cmd/3` without `env:` or a timeout | `run_command printenv`; `run_command sleep 1000000` |
| Whole-proposal timeout, and per-task override | `LLMProposalBuilder.within_task_timeout/2`, `task_timeout_ms/0`; `Current.validate_timeout/1` (1 s to 1 h) | Tests in `llm_proposal_test.exs` and `submit_task_test.exs` |
| `file_patch` exact-match only | `EffectApplicator.apply_patch/3` (`--batch --forward --fuzz=0`) | Patch a file that changed after approval |
| `write_file` refuses an existing file | `EffectApplicator.do_apply/3` (WriteFile) | |
| First failure or false claim stops apply; no rollback | `WorkflowOrchestrator.apply_intents_streaming/4` | |
| Interrupted apply is failed, not resumed | `WorkflowOrchestrator.recover/3` (status `:applying`) → `fail_interrupted_effects/1` | Kill the runtime during a slow command, restart |
| Hash chain verified on start; bad commit refused | `Current.Consensus.Log.put/2`, `init/1`; `Commit.hash/1` | Flip a byte in a closed segment; startup must fail naming it |
| Artifacts are content-addressed but not re-verified on read | `Current.BlobStore.put/1`, `read/1` | |
| Reviewer identity is the client's `$USER` | `Current.CLI.reviewer/0` | |
| No explicit TLS options on provider calls | `LLMClient.OpenAI` and `LLMClient.Anthropic` `:httpc.request/4` calls | Point an endpoint at a host with a bad certificate |
