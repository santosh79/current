# Proposal Response Wire Schema

This document specifies the JSON the agent (LLM) must return when asked
to produce a proposal, and is the contract between two things that don't
otherwise check each other: the prompt that tells the model what to
send, and `Current.ProposalDecoder`, which parses what it sends back.

A reply takes one of two shapes:

- a **proposal** (`{"intents": [...]}`), which ends the exchange -- see
  [Top-level shape](#top-level-shape);
- a **context request** (`{"observe": [...]}`), which asks to see more
  of the project first -- see [Context requests](#context-requests).

If you change the prompt's description of the response format, update
this document. If you change what `ProposalDecoder` accepts, update this
document. Treat drift between this file and either of those two as a bug.

A machine-checkable version of this contract lives at
`priv/schema/proposal_response.schema.json`;
`test/unit/proposal_decoder_test.exs` asserts that every well-formed
fixture in that test file validates against it, so the two can't
silently drift apart. The schema's top level describes a proposal; the
context request is `definitions.context_request` in the same file.

The prompt is built by `Current.LLMProposalBuilder`. It includes that JSON
schema verbatim -- so the `description`s in it are instructions the model
reads -- followed by the `edit_file` rules and example described
under [`edit_file`](#edit_file) below, the rules for context requests,
and the project's layout (paths and sizes, no file contents).

## Where this fits

```
LLM raw text response
        │
        ▼
Current.LLMClient          -- talks to the model, owns connection/timeout
        │
        │ raw bytes (this document describes their shape)
        ▼
Current.BlobStore.put/1    -- raw bytes preserved for provenance, always,
        │                     whether decode succeeds or fails
        ▼
Current.ProposalDecoder    -- can these bytes become a Proposal.t(), or
        │                     a list of Observation.t()?
        │
        ├── failure ──────► Current.Error.ProposalProductionError{stage: :decode}
        │
        ├── context request ► Current.Observer makes each observation;
        │                     the model is asked again with the results
        │                     (back to the top, a bounded number of times)
        ▼
Current.Proposal.t()       -- a real, typed proposal now exists, carrying
        │                     the observations that led to it
        │
        ▼
Current.IntentValidator    -- is this proposal acceptable to run?
        │
        ├── failure ──────► ProposalValidationFailed
        │
        ▼
ProposalValidated
```

**Decoding and validating are different questions, deliberately.**
`ProposalDecoder` only asks "is this well-formed enough to become typed
intents" — JSON parses, required fields are present and the right kind of
value, refs are unique and referenced refs exist. It does **not** check things like "does this
claim reference an earlier intent" or "does this write_file's target
already exist" — those are `IntentValidator`'s job, once real
`Current.Intent.t()` structs exist to check. See `IntentValidator`'s
module doc for that boundary in more detail.

## Top-level shape

```json
{
  "justification": "add email validation to the signup flow",
  "claims": ["invalid emails are rejected", "existing behavior is unchanged"],
  "dependencies": [],
  "intents": [ /* array of intent objects, see below */ ]
}
```

| Field            | Type              | Required | Notes                                                    |
|------------------|-------------------|----------|-----------------------------------------------------------|
| `justification`  | string            | no       | Free text. Absent or non-string → decodes as `nil`.        |
| `claims`         | array of strings  | no       | Free-text list. Absent, or containing a non-string → `nil`.|
| `dependencies`   | array of strings  | no       | Same rule as `claims`.                                     |
| `intents`        | array of objects  | **yes**  | Must be present and a JSON array, even if empty (`[]`).    |

Anything at the top level besides these four keys is ignored, not
rejected -- with one exception: `observe`. A reply with `observe` and no
`intents` is a context request (next section); a reply with both is a
decode failure.

## Context requests

The model is shown the project's layout, not its files. To see more
before proposing, it replies with a context request instead of a
proposal:

```json
{
  "observe": [
    { "reason": "see how sign-up validates input",
      "intent": { "type": "read_file", "path": "lib/signup.ex" } },
    { "reason": "find the other modules",
      "intent": { "type": "glob", "pattern": "lib/**/*.ex" } },
    { "intent": { "type": "grep", "pattern": "validate_email", "paths": ["lib/signup.ex"] } }
  ]
}
```

| Field     | Type             | Required | Notes                                          |
|-----------|------------------|----------|------------------------------------------------|
| `observe` | array of objects | **yes**  | Must be a non-empty JSON array of observations. |

**Each entry is an observation** -- one thing to look at, and why:

| Field    | Type   | Required | Notes                                                                 |
|----------|--------|----------|-----------------------------------------------------------------------|
| `intent` | object | **yes**  | A `read_file`, `glob` or `grep`, with the fields it has in a proposal. |
| `reason` | string | no       | Why the model wants to see this. Recorded with the proposal.           |

Decode failures: `observe` not an array or empty; an entry that isn't an
object or has no `intent` (a bare intent is not an observation); an
`intent` of any other type, or missing one of its required fields; a
`reason` that isn't a string. A `ref` on an observation's intent is
ignored.

`ProposalDecoder.decode_reply/2` accepts either reply shape and says
which it got; a context request decodes to a list of
`Current.Observation.t()`, each with a real id and status `:requested`.
`ProposalDecoder.decode/2` accepts only a proposal.

The model says which shape it is sending by the key it uses. Nothing is
inferred from the intents: a proposal made only of reads is a legitimate
proposal.

### What happens to a context request

Nothing is proposed and nothing is changed. `Current.Observer` makes
each observation, in order, and the model is called again with the same
prompt plus everything it has been shown so far. Each observation is
settled one of two ways:

- **shown** -- the read ran, and the model is given the result: a file's
  contents, the paths a glob matched, or the lines a grep matched.
- **refused** -- the model is told why instead. This is an answer, not a
  failure of the workflow: a mistyped path is something the model can
  correct on its next reply.

An observation is refused when its path is outside the project (with
symlinks followed), when it names something `Current.ReadPolicy` never
shows a model (dependencies, build output, lockfiles, `.env*`), when the
file doesn't exist, is binary or is too large, or when a limit below is
reached. Glob results are filtered by the same policy.

The exchange is bounded (all hard-coded today):

| Limit                                      | Value      |
|--------------------------------------------|------------|
| Context requests before a proposal is due  | 8          |
| Observations made per reply                | 20         |
| Largest file `read_file` will show         | 200 KB     |
| Paths or lines shown per glob / grep       | 200        |
| Total result text shown per task           | 400 KB     |
| Whole build, every call and read           | 10 minutes |

A model that sends a context request after its last allowed one fails
production at the `:context_budget` stage; running out of time fails it
at `:timeout`.

### What is recorded

The observations are attached to the proposal they led to, as
`Current.Proposal.observations`, and so end up in the `ProposalProduced`
event. Each records:

| Field               | Meaning                                                              |
|---------------------|----------------------------------------------------------------------|
| `id`                | Assigned by the decoder.                                             |
| `intent`, `reason`  | What the model asked for and why, as it wrote them.                  |
| `round`             | Which context request it was part of (1 for the first).              |
| `reply_artifact_id` | The model's raw reply that asked for it.                             |
| `status`            | `:shown` or `:refused`.                                              |
| `artifact_id`       | When shown: the artifact holding what the model was shown.           |
| `error`             | When refused: why.                                                   |

An observation holds ids, never contents. For `read_file` the artifact
is the file exactly as read; for `glob` and `grep` it is the listing as
shown, after the read policy and the limits.

A production that fails has no proposal, and its observations are not
recorded.

## Paths

Every path field (`path`, `grep`'s `paths`, `glob`'s `base_dir`) is
relative to the project root -- the directory the task was submitted for,
e.g. `lib/signup.ex`. That holds for the intents in a proposal and for
the intent inside an observation alike.

What is recorded, and when:

1. The model's raw response is stored as a blob before decoding,
   untouched -- paths exactly as the model wrote them.
2. Decoding stores each `contents`, `old_string` and `new_string` payload as a blob. It records
   nothing else; the decoded intents still carry the model's paths.
3. `WorkflowOrchestrator` resolves every path against the project
   directory, and only then records the proposal, in the
   `ProposalProduced` event it commits to the log.

So the proposal as recorded -- and everything that reads it
(`IntentValidator`, `ProposalStore`, `EffectApplicator`, replay) -- only
ever has absolute, resolved paths, while the raw-output blob keeps what
the model actually sent.

`IntentValidator` then rejects any path that contains a `..` segment or
lands outside the project directory. `EffectApplicator` checks again at
apply time, with symlinks followed.

An observation's paths are handled differently, because it is made
before any proposal exists. `Current.Observer` resolves them against the
project directory at the moment it reads, applies the same containment
check with symlinks followed, and then the read policy. The observation
is recorded with the paths as the model wrote them.

## Referencing intents: `ref` and `source_intent_ref`

The model cannot know Current's internal ids in advance, and must not
invent them. Instead, any intent may optionally carry a `ref` — an
arbitrary string, meaningful only within this one response — and any
`claim`'s evidence may cite another intent by `source_intent_ref` instead
of a real id:

```json
{ "ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"] }
```

```json
{ "type": "claim", "statement": "tests pass",
  "evidence": { "source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0 } }
```

`ProposalDecoder` assigns every intent a real `Current.Id.t()` and
resolves `source_intent_ref` to that id. A `source_intent_ref` that
doesn't match any `ref` in the response is a decode failure.

`ref`s must be unique within a response. A duplicate `ref` is a decode
failure, whether or not anything cites it: evidence has to point at
exactly one intent.

**Ordering is not checked at decode time.** A claim may cite a ref
belonging to an intent that appears later in the `intents` array, and
decoding still succeeds — resolving a ref is purely "does this name exist
anywhere in this response," not "does it precede me." Whether the
referenced intent actually ran *before* this claim, so that the claim
could ever be evaluated against a real result, is checked afterward by
`IntentValidator`, which walks `intents` in order and rejects a claim
whose reference doesn't precede it. Put a claim before the intent it
depends on in the array and you'll get a clean `ProposalValidationFailed`,
not a `ProposalProductionFailed`.

## Intent types

Every intent object must have a `"type"` field. An intent with no
recognized `"type"`, or with `"type"` missing entirely, is a decode
failure. Each type below lists its own required and optional fields;
fields not listed are ignored.

### `read_file`

```json
{ "type": "read_file", "path": "lib/signup.ex" }
```

| Field  | Type   | Required |
|--------|--------|----------|
| `path` | string | yes      |

### `write_file`

```json
{ "type": "write_file", "path": "lib/new_module.ex", "contents": "defmodule New do\nend\n" }
```

| Field      | Type   | Required |
|------------|--------|----------|
| `path`     | string | yes      |
| `contents` | string | yes      |

`contents` is written to `BlobStore` by the decoder; the resulting intent
carries a `contents_artifact_id`, not the raw text.

`write_file` only ever **creates** a file: `EffectApplicator` refuses it
if the target already exists. There is no overwrite; change an existing
file with `edit_file`. (Whether the file exists on disk is checked at
apply time, not validation time, since it can change in between. The
exception is a path the same proposal already wrote or edited earlier:
`IntentValidator` refuses that, because the proposal alone shows it. A
path the proposal deletes first can be written again.)

### `delete_file`

```json
{ "type": "delete_file", "path": "lib/obsolete.ex" }
```

| Field  | Type   | Required |
|--------|--------|----------|
| `path` | string | yes      |

### `edit_file`

```json
{ "type": "edit_file", "path": "lib/signup.ex", "old_string": "defmodule Signup do\n", "new_string": "defmodule Signup do\n  def validate_email(email), do: String.contains?(email, \"@\")\n" }
```

| Field         | Type    | Required | Default |
|---------------|---------|----------|---------|
| `path`        | string  | yes      | —       |
| `old_string`  | string  | yes      | —       |
| `new_string`  | string  | yes      | —       |
| `replace_all` | boolean | no       | `false` |

`old_string` and `new_string` are written to `BlobStore`; the resulting
intent carries an `old_artifact_id` and a `new_artifact_id`, not the raw
text. The target file must already exist (to create one, use
`write_file`).

**Matching.** `Current.Edit.replace/4` does the replacing, and it is the
only place the rules live: `IntentValidator` calls it to refuse an edit
that cannot apply, and `EffectApplicator` calls it to apply the edit.

- `old_string` must occur in the file **exactly once**, byte for byte --
  whitespace and indentation included. Zero matches, or more than one, is
  an error. There is no fuzzy matching.
- With `"replace_all": true`, `old_string` must occur at least once, and
  every occurrence is replaced.
- `new_string` may be empty, which deletes `old_string`.
- The decoder rejects an empty `old_string` (to create a file, use
  `write_file`) and an `old_string` identical to `new_string`.
- `old_string` is plain text. It is not a regular expression, and it must
  not carry line numbers copied from a listing.

The prompt states these rules and gives a worked example
(`LLMProposalBuilder.edit_file_example/0`). The model is told to edit only
files whose contents it has been shown; nothing enforces that yet.

**Several edits to one file.** Edits to the same file are applied in order,
so each must match the file as the earlier ones leave it. `IntentValidator`
checks them the same way: it keeps an in-memory picture of each file the
proposal touches and checks each edit against it. A second edit may depend
on the first, and one the first made ambiguous or impossible is refused at
validation. The picture comes from the proposal's own `write_file`,
`edit_file` and `delete_file` intents, so an `edit_file` may also follow a
`write_file` that creates the file, and fails after a `delete_file` of it.
A `run_command` can change files unpredictably and is not modelled, so
edits after one can still pass validation and fail on apply.

### `run_command`

```json
{ "type": "run_command", "cmd": "mix", "args": ["test"] }
```

| Field  | Type             | Required | Default |
|--------|------------------|----------|---------|
| `cmd`  | string           | yes      | —       |
| `args` | array of strings | no       | `[]`    |

`cmd` is an executable run directly in the project root with `args` --
not through a shell, so pipes, redirects, `&&` and globbing don't apply.

### `grep`

```json
{ "type": "grep", "pattern": "validate_email", "paths": ["lib/signup.ex"] }
```

| Field     | Type             | Required |
|-----------|------------------|----------|
| `pattern` | string           | yes      |
| `paths`   | array of strings | yes      |

`pattern` is a literal string matched line by line, not a regular
expression. `paths` are files; directories are not searched (find the
files with `glob` first).

### `glob`

```json
{ "type": "glob", "pattern": "**/*.ex", "base_dir": "lib" }
```

| Field      | Type   | Required | Default |
|------------|--------|----------|---------|
| `pattern`  | string | yes      | —       |
| `base_dir` | string | no       | `"."`   |

`pattern` must be a relative path; this isn't checked at decode time (see
"What this schema does not enforce," below).

### `claim`

```json
{
  "type": "claim",
  "statement": "tests pass",
  "evidence": {
    "source_intent_ref": "cmd_1",
    "condition": "exit_code_equals",
    "value": 0
  }
}
```

| Field       | Type   | Required |
|-------------|--------|----------|
| `statement` | string | yes      |
| `evidence`  | object | no       |

A claim with no `evidence` at all decodes successfully, with
`evidence: nil` on the resulting intent — `IntentValidator` is what
rejects an evidence-less claim, not the decoder.

**`evidence` object**, when present:

| Field                | Type   | Required | Notes                                                          |
|----------------------|--------|----------|------------------------------------------------------------------|
| `source_intent_ref`  | string | yes      | Must match a `ref` on some intent in this same response.        |
| `condition`          | string | yes      | One of the values below — anything else is a decode failure.    |
| `value`              | any    | yes      | Compared against the referenced intent's result at apply time.  |

**Recognized `condition` values** (decoded via an explicit allowlist —
never minted as atoms from arbitrary model text):

| Wire value                    | Meaningful against            |
|--------------------------------|--------------------------------|
| `"match_count_greater_than"`  | `grep`, `glob`                 |
| `"match_count_equals"`        | `grep`                         |
| `"exit_code_equals"`          | `run_command`                  |

Whether a given `condition` is actually meaningful for the *type* of
intent it references (e.g. `exit_code_equals` against a `grep`, which can
never produce an exit code) is **not** checked by the decoder — that's
`IntentValidator`'s job, and it's the same event-level distinction as
ordering: an incompatible condition/type pairing decodes fine, then fails
validation.

### `report`

```json
{ "type": "report", "summary": "email validation added, tests pass" }
```

| Field     | Type   | Required |
|-----------|--------|----------|
| `summary` | string | no       |

## What this schema does not enforce

Deliberately left to `IntentValidator`, not the decoder, because these
depend on the *other* intents in the proposal or on the environment the
proposal will run against — not on whether the response is well-formed:

- A claim referencing an intent that appears **after** it in `intents`.
- A claim's `condition` being incompatible with the *type* of intent its
  evidence references (e.g. `exit_code_equals` against a `grep`).
- Whether a `path` exists, or a referenced blob resolves. Existence is
  judged as the proposal's earlier intents leave the file: a path an
  earlier `write_file` creates exists, and one an earlier `delete_file`
  removes does not. A path no earlier intent touched is looked up on disk.
- `glob`'s `pattern` being relative rather than absolute.
- Whether `run_command`'s `cmd` is actually on `PATH` — this can differ
  between validation time and apply time, so it's checked only at apply
  time, by `EffectApplicator`.
- Whether a `write_file` target already exists on disk (apply fails if it
  does), for the same reason. A `write_file` to a path the same proposal
  already wrote or edited is refused at validation, since the proposal
  alone shows it.
- Whether an `edit_file`'s `old_string` is in its file. The decoder only
  checks that the strings are well-formed. `IntentValidator` checks the
  edit against the file as the proposal's earlier intents leave it (see
  "Several edits to one file" above), and `EffectApplicator` checks again
  at apply time against the file as it is then, because the file can
  change in between and a `run_command` can change it in ways validation
  doesn't model. A proposal can therefore validate and still fail on
  apply.
- Whether an `edit_file` targets a file the model was actually shown.
  The proposal's `observations` say what it saw, so this is a candidate
  for `IntentValidator`.

For context requests, the decoder checks shape only. Whether an
observation's path exists, is inside the project, or may be shown is
decided by `Observer` when it makes the observation, and the answer goes
back to the model, not into a failure.

## Full example: a proposal

```json
{
  "justification": "add email validation to the signup flow",
  "claims": ["invalid emails are rejected", "existing behavior is unchanged"],
  "dependencies": [],
  "intents": [
    {
      "ref": "edit_1",
      "type": "edit_file",
      "path": "lib/signup.ex",
      "old_string": "defmodule Signup do\n",
      "new_string": "defmodule Signup do\n  def validate_email(email), do: String.contains?(email, \"@\")\n"
    },
    {
      "ref": "cmd_1",
      "type": "run_command",
      "cmd": "mix",
      "args": ["test"]
    },
    {
      "type": "claim",
      "statement": "tests pass",
      "evidence": {
        "source_intent_ref": "cmd_1",
        "condition": "exit_code_equals",
        "value": 0
      }
    }
  ]
}
```

## Full example: a context request

```json
{
  "observe": [
    {
      "reason": "find where sign-up lives",
      "intent": { "type": "glob", "pattern": "lib/**/*signup*" }
    },
    {
      "reason": "see the current validation before changing it",
      "intent": { "type": "read_file", "path": "lib/signup.ex" }
    }
  ]
}
```

## Versioning

This is version 1 of the wire schema — there is no `"version"` field on
the response itself yet. The context request was added as a second reply
shape without changing the proposal's, so it is additive. If the schema needs a breaking change later
(new required field, changed meaning of an existing one), add an explicit
`"version"` field to the top-level object and give `ProposalDecoder` a
per-version code path, the same way `Current.Event.Versioned` handles
schema evolution for events. Until then, all changes to this document
must be additive: new optional fields are fine; changing what an existing
field means, or making an optional field required, is not.

