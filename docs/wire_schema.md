# Proposal Response Wire Schema

This document specifies the JSON shape the agent (LLM) must return when
asked to produce a proposal, and is the contract between two things that
don't otherwise check each other: the prompt that tells the model what to
send, and `Current.ProposalDecoder`, which parses what it sends back.

If you change the prompt's description of the response format, update
this document. If you change what `ProposalDecoder` accepts, update this
document. Treat drift between this file and either of those two as a bug.

A machine-checkable version of this contract lives at
`priv/schema/proposal_response.schema.json`; `test/proposal_decoder_test.exs`
asserts that every well-formed fixture in that test file validates against
it, so the two can't silently drift apart.

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
Current.ProposalDecoder    -- can these bytes become a Proposal.t()?
        │
        ├── failure ──────► Current.ProposalProductionError{stage: :decode}
        │
        ▼
Current.Proposal.t()       -- a real, typed proposal now exists
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
value, referenced refs exist. It does **not** check things like "does this
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

Anything at the top level besides these four keys is ignored, not rejected.

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

### `delete_file`

```json
{ "type": "delete_file", "path": "lib/obsolete.ex" }
```

| Field  | Type   | Required |
|--------|--------|----------|
| `path` | string | yes      |

### `file_patch`

```json
{ "type": "file_patch", "path": "lib/signup.ex", "diff": "--- a/signup.ex\n+++ b/signup.ex\n@@ ... @@\n" }
```

| Field  | Type   | Required |
|--------|--------|----------|
| `path` | string | yes      |
| `diff` | string | yes      |

`diff` must be a unified diff. It's written to `BlobStore`; the resulting
intent carries a `diff_artifact_id`.

### `run_command`

```json
{ "type": "run_command", "cmd": "mix", "args": ["test"] }
```

| Field  | Type             | Required | Default |
|--------|------------------|----------|---------|
| `cmd`  | string           | yes      | —       |
| `args` | array of strings | no       | `[]`    |

### `grep`

```json
{ "type": "grep", "pattern": "validate_email", "paths": ["lib/signup.ex"] }
```

| Field     | Type             | Required |
|-----------|------------------|----------|
| `pattern` | string           | yes      |
| `paths`   | array of strings | yes      |

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
- Whether a `path` exists on disk, or a referenced blob resolves.
- `glob`'s `pattern` being relative rather than absolute.
- Whether `run_command`'s `cmd` is actually on `PATH` — this can differ
  between validation time and apply time, so it's checked only at apply
  time, by `EffectApplicator`.

## Full example

```json
{
  "justification": "add email validation to the signup flow",
  "claims": ["invalid emails are rejected", "existing behavior is unchanged"],
  "dependencies": [],
  "intents": [
    {
      "ref": "patch_1",
      "type": "file_patch",
      "path": "lib/signup.ex",
      "diff": "--- a/signup.ex\n+++ b/signup.ex\n@@ -1,2 +1,3 @@\n defmodule Signup do\n+  def validate_email(email), do: String.contains?(email, \"@\")\n end\n"
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

## Versioning

This is version 1 of the wire schema — there is no `"version"` field on
the response itself yet. If the schema needs a breaking change later
(new required field, changed meaning of an existing one), add an explicit
`"version"` field to the top-level object and give `ProposalDecoder` a
per-version code path, the same way `Current.Event.Versioned` handles
schema evolution for events. Until then, all changes to this document
must be additive: new optional fields are fine; changing what an existing
field means, or making an optional field required, is not.
