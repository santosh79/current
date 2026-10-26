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
  HTTP API has full control of it: they can submit tasks, approve proposals
  and apply them.
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
           ┌────────────────────────────────────────┐
           │ HTTP clients: current CLI, scripts, …  │
           └───────────────────┬────────────────────┘
                               │ ① HTTP/JSON, no authentication
  ┌────────────────────────────▼─────────────────────────────┐
  │ runtime · bin/current-server · runs as one OS user       │
  │                                                          │
  │   HTTP API ─▶ Current.API ─▶ orchestrator                │
  │                                                          │
  │   LLMProposalBuilder ─▶ Decoder ─▶ Validator ─┐          │
  │     │   └─ Observer                           │          │
  │     │        │            EffectApplicator ───┤          │
  │     │        │              │                 ▼          │
  │     │        │              │          log + artifacts   │
  │     │        │              │                 │          │
  └─────┼────────┼──────────────┼─────────────────┼──────────┘
        ②        ③              ④                 ⑤
      HTTPS   read-only   write, edit,         append
        │        │        run commands            │
        ▼        ▼              ▼                 ▼
    OpenAI /  project     project dir;        data dir
    Anthropic dir         via commands,       (_data/)
                          the OS, the
                          network, all
                          the user can read
                          
```

| # | Boundary | What crosses it | Trusted side |
|---|---|---|---|
| ① | HTTP client ↔ runtime | Tasks (including which directory to work in), approvals, applies, queries, artifact contents | Neither. The API does not authenticate; whoever can reach the port is treated as the operator (see T6) |
| ② | Runtime ↔ model provider | Prompts (project layout, files the model asked for), replies | Runtime. The reply is untrusted input |
| ③ | Runtime ↔ project, while observing | Reads chosen by the model | Runtime, which decides what may be read |
| ④ | Runtime ↔ project and OS, while applying | Writes, edits, deletes, commands | Runtime, once an approval and an apply request have arrived over ①. Who sent them isn’t verified |
| ⑤ | Runtime ↔ data dir | Log segments, artifacts | Whoever can write the directory. The hash chain shows corruption, not tampering |

---

## Assets

| Asset | Why it matters |
|---|---|
| The project directory | The thing being changed. Its integrity is the point |
| Everything else the runtime's user can reach | Home directory, SSH keys, other repos, cloud credentials. Reachable by commands |
| API keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) | Spend money; in the runtime's environment |
| Access to the HTTP API port | Whoever can reach it controls the runtime (T6) |
| Secrets inside the project | Can reach the provider (via observe) or the data dir (via read results and command output) |
| The data dir (`_data/`) | The record. Also holds copies of everything read, deleted, edited or printed |
| The reviewer's attention | The last line of defence. Can be exhausted or misled |

---

## Adversaries

**A1. A mistaken model.** The common case. Proposes the wrong edit, a
destructive command, or a claim that isn't true.

**A2. A model steered by content it reads** (prompt injection). The model
reads files in the project: source, docs, test fixtures, vendored code,
issue text pasted into a task. Any of it can contain instructions. In
effect, *anyone who can put text into the project, or into the prompt, can
write the proposal.*

**A3. Another user or process on the same host.** May be able to read the
data dir, or reach the HTTP API on 127.0.0.1 (every local user can).

**A4. Someone on the network.** May be able to reach the HTTP API if it
is bound beyond localhost, or exposed by a proxy or tunnel.

**A5. The model provider.** Sees every prompt. Out of scope as an attacker,
but in scope for what you send it.

---

## Assumptions

- The machine, the OS user running the runtime, and the Elixir/Erlang
  installation are not compromised.
- Only you can write the data dir.
- Only you can reach the HTTP API. It listens on 127.0.0.1 by default, which
  still includes every other user and process on this machine; beyond that,
  restricting access is up to you (see
  [Running Current more safely](#running-current-more-safely); Current does
  not enforce it).
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
  follows symlinks. An `edit_file` reads the file, replaces the text in
  memory and writes the whole file back to the checked path.
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
- A proposal can `edit_file` something another tool executes:
  `mix.exs`, `package.json` scripts, a `Makefile`, CI configuration, or a
  Git hook under `.git/hooks/`. The read policy hides `.git` from the model,
  but nothing stops a proposal from *writing* there.
- An innocent-looking command runs project code: `mix test` executes every
  test and compiles every dependency.
- Commands inherit the runtime's environment, so they can read
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and anything else exported to the
  server. They run with full network access, and can read anything else the
  user can.

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
  and the before/after of every edited or deleted file;
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

### T6. An unauthorized caller controls the runtime

Current's control plane is an HTTP API. It does not authenticate callers or
implement identity-based access control, and it does not try to defend
against web pages or other clients: whoever can send it a request is treated
as its operator. It listens on 127.0.0.1 by default.

What a caller with access to the port can do:

- submit tasks, **for any directory the runtime's user can read**. The model
  is shown that directory's layout and the files it asks to read, and that
  content is sent to the model provider (T4);
- read proposals and artifacts, which include file contents;
- approve or reject proposals, and request that an approved proposal be
  applied. Applying can run arbitrary commands as the runtime's user (T3).

On a shared machine, other OS users can reach 127.0.0.1 too.

Current enforces workflow invariants independently of caller identity: a
proposal that hasn't reached the required state can't be applied. It does
not check that the caller approving a proposal is an authorized person, and
`reviewed_by` is supplied by the client and is not an authenticated identity.

**Status: open by design.** Restricting who can reach the API is the
deployment's job: loopback binding, network policy, a reverse proxy or
gateway, a tailnet. Remote or multi-user use needs that layer to
authenticate callers and limit which routes each may use, notably
`POST /v1/tasks`, `POST /v1/proposals/:id/approve` and
`POST /v1/proposals/:id/apply`.

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

Before contents of edited and deleted files are kept as artifacts, so they
can be restored by hand.

**Status: partly mitigated.** Recommended: atomic apply (apply to a copy,
promote only if every intent succeeds). Until then: keep the project under
version control, and start from a clean working tree.

### T10. The approved proposal no longer fits the world

Approval can come long after validation. What was approved cannot change:
the proposal and every diff and file it carries are stored immutably,
content-addressed, in the log. But the project can change.

- `edit_file` needs its `old_string` to match the file exactly once (or
  at least once with `replace_all`), so an edit fails rather than applying
  somewhere unexpected. It is checked at validation and again at apply
  time. The read and the write inside one edit are separate steps, so a
  change made to the file between them is overwritten.
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

OpenAI and Anthropic requests use Erlang's `:httpc` through
`Current.LLMClient.HTTP`. All four operations (completion and model listing
for both providers) explicitly pass `ssl:` options with `verify: :verify_peer`,
OS CA certificates from `:public_key.cacerts_get/0`, HTTPS hostname matching,
and TLS 1.2/1.3 only. Redirects are not followed automatically. A missing or
empty OS CA store returns `{:error, :no_ca_certificates}` rather than raising
or falling back to unverified TLS; install the OS `ca-certificates` package
in minimal containers.

Endpoints default to the real provider APIs. Operators may override the
base URL (including `/v1`) per provider, for example:

```elixir
config :current, Current.LLMClient.OpenAI,
  base_url: "https://api.openai.com/v1"

config :current, Current.LLMClient.Anthropic,
  base_url: "https://api.anthropic.com/v1"
```

Overrides are read per call, must use HTTPS, and may not contain embedded
credentials, a query or a fragment. Treat this configuration as trusted:
the configured host receives prompts and API keys. There is no configuration
switch to disable certificate verification.

Offline tests in `test/llm_integration/tls_test.exs` use a loopback TLS
listener with a freshly generated private CA and assert an `unknown_ca` TLS
alert for all four provider operations. A verification-disabled positive
control in the test alone checks that the listener actually serves HTTP.
`http_test.exs` covers the shared TLS options, CA-loading errors and URL
validation. These tests require no real API keys or external network.

API keys are read from the environment for each call and sent only in
request headers. Error bodies from the provider may be recorded with a
failed workflow.

**Status: mitigated.** Certificate trust still depends on the operator's OS
CA store and trusted endpoint configuration.

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

- Keep the HTTP API bound to 127.0.0.1 (the default), and don't expose it
  directly to an untrusted network. On a machine with other users, remember
  that they can reach 127.0.0.1 as well.
- For remote access, put Current behind a reverse proxy or gateway that
  authenticates callers and controls which routes each may use, and keep the
  runtime reachable only from that gateway.
- Restrict `POST /v1/tasks`, `POST /v1/proposals/:id/approve` and
  `POST /v1/proposals/:id/apply` to authorized callers. Together they can
  cause arbitrary code to run with the runtime's privileges.
- Treat anyone who can reach the API as trusted unless a layer outside
  Current enforces otherwise.

**Protect the record**

- `chmod 700` the data dir. It contains copies of everything read, deleted,
  edited and printed.
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
- Expose the HTTP API directly to an untrusted network.

---

## Mitigations by priority

| Priority | Change | Addresses |
|---|---|---|
| 1 (implemented) | Shared explicit TLS verification for provider calls; offline bad-certificate refusal tests for both providers and operations | T12 |
| 2 | Command timeout (kill the process group) and output cap | T11 |
| 3 | Minimal environment for commands | T3, T5 |
| 4 | Command allowlist, enforced at validation | T3 |
| 5 | Data dir created `0700`; configurable read deny list; read policy on proposed reads | T4, T5 |
| 6 | Review: commands and sensitive paths first; claims shown with what is checked; control characters stripped | T8 |
| 7 | Atomic apply, and refuse apply if touched files changed | T2, T9, T10 |
| 8 | Deployment-level authentication and authorization guidance for remote or multi-user operation | T6 |
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
| Only `:apply` workflows accept approval, from `waiting_for_approval` only | `WorkflowReducer.apply_event_helper/2` (`ProposalApproved` matches `mode: :apply`); `Current.API.require_apply_mode/1` | Commit `ProposalApproved` for a plan-mode workflow directly; it must be rejected |
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
| `edit_file` exact-match only | `Current.Edit.replace/4`, called by `IntentValidator` and by `EffectApplicator.do_apply/3` (EditFile) | Change the file after approval so `old_string` no longer matches, or matches twice |
| `write_file` refuses an existing file | `EffectApplicator.do_apply/3` (WriteFile) | |
| First failure or false claim stops apply; no rollback | `WorkflowOrchestrator.apply_intents_streaming/4` | |
| Interrupted apply is failed, not resumed | `WorkflowOrchestrator.recover/3` (status `:applying`) → `fail_interrupted_effects/1` | Kill the runtime during a slow command, restart |
| Hash chain verified on start; bad commit refused | `Current.Consensus.Log.put/2`, `init/1`; `Commit.hash/1` | Flip a byte in a closed segment; startup must fail naming it |
| Artifacts are content-addressed but not re-verified on read | `Current.BlobStore.put/1`, `read/1` | |
| Reviewer identity is the client's `$USER` | `Current.CLI.reviewer/0` | |
| Provider calls explicitly verify certificates and HTTPS hostnames, using TLS 1.2/1.3 and OS CAs; CA-loading failures return an error | `Current.LLMClient.HTTP.request/3` and `ssl_opts/1`, used by OpenAI and Anthropic for completion and model listing | `test/llm_integration/tls_test.exs` checks untrusted-CA refusal for all four operations; `http_test.exs` checks policy and missing CA stores |
