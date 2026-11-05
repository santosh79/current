# Validation

There is no `Validator` module per type. Validation happens in layers, each
answering a different question and each running at a different time. The
rules below are what the code does today.

| Layer | Module | Question | When |
|---|---|---|---|
| Decode | `ProposalDecoder` | Can these bytes be a proposal at all? | When a model reply arrives |
| Absolutize | `IntentPaths.absolutize/2` | (not a check) make every path absolute against the project | Before the proposal is recorded |
| Validate | `IntentValidator` | Is this proposal well-formed and in bounds right now? | Before it is shown for approval |
| Apply | `EffectApplicator` | Is this still safe and possible on the live filesystem? | Just before each effect |
| Events | `Event.valid?/1`, `Event.Schema`, `WorkflowReducer` | Is this a known event, and a legal next step? | When events are read or reduced |
| Log | `Consensus.Log` | Is the chain intact? | Each commit, and on start |

Validation is deliberately narrower than "will this apply". The project can
change between validation and approval, and between approval and apply.
Anything that can change is checked again at apply time, or only then.

---

## Decoding: `ProposalDecoder`

`ProposalDecoder.decode(raw, workflow_id)` turns the model's raw text into a
`%Proposal{}` or returns `{:error, message}`. It never raises. It checks:

- the JSON parses and has the expected shape (see
  [wire_schema.md](wire_schema.md));
- every intent has a known type and its required fields;
- references between intents resolve (a claim's `source_intent_ref` must name
  an intent in the same proposal).

It assigns real ids. It also stores inline text (file contents, `old_string`
and `new_string`) as artifacts, so the intents it returns hold artifact ids.
`decode_reply/2` also accepts the other legal reply, `{"observe": [...]}`,
and says which one it got.

It does not decide whether a proposal is acceptable.

---

## Validating: `IntentValidator`

```elixir
@spec validate(Proposal.t(), Path.t()) :: :ok | {:error, ValidationError.t()}
IntentValidator.validate(proposal, project_dir)
```

Intents are checked in order and the **first** failure stops validation. Each
failure is a `%ValidationError{intent_id, reason, details}`.

Every intent first passes the **path check** (`IntentPaths.violation/2`).
Every path field must be absolute, must contain no `..` segment, and must
lie inside `project_dir`. The check is lexical and does not follow symlinks.
A relative path here means the caller skipped absolutizing, and it is
rejected rather than resolved against the node's working directory.

Then the per-intent rules:

| Intent | Checked | Left to apply time |
|---|---|---|
| `read_file` | `path` is a regular file | whether the file still exists when applied |
| `write_file` | the contents artifact exists; rejects a path an earlier proposal intent left present | whether the path already exists on disk when applied |
| `edit_file` | `path` exists; the `old` and `new` artifacts exist; `Current.Edit.replace/4` succeeds against the file as earlier intents in the proposal have left it (see below) | the same check again, against the file as it is then |
| `delete_file` | `path` is a non-empty string | a missing file counts as already deleted |
| `run_command` | `cmd` is a non-empty string; `args` is a list of strings | whether `cmd` is in the `allowed_commands` allowlist, and whether the executable exists |
| `grep` | every path is a regular file | whether the files still exist when applied |
| `glob` | `pattern` is relative; `base_dir` is an existing directory on disk | |
| `claim` | evidence is present; `source_intent_id` names an intent **earlier in the proposal**; the condition can be evaluated against that kind of intent | whether the result satisfies it |
| `report` | nothing | |

Every member of `Current.Intent.t()` has an explicit clause. There is no
catch-all, so an intent type without a rule fails loudly instead of being
silently accepted.

### What counts as a valid edit

`Current.Edit.replace(contents, old, new, replace_all)` is the single
definition of a valid `edit_file`. It is pure (no files, no artifacts) and
is called both here and at apply time, so the two cannot disagree.

| Case | Result |
|---|---|
| `old` is empty | error: use `write_file` to create a file |
| `old` not found | error: it must match exactly, whitespace and indentation included |
| `old` found once | ok, 1 replacement |
| `old` found more than once, `replace_all` false | error: include more surrounding lines, or set `replace_all` |
| `old` found more than once, `replace_all` true | ok, every occurrence replaced |

Matching is byte for byte.

### File state across intents

`EffectApplicator` applies intents in order, so each one sees the files as
the earlier ones left them. `IntentValidator` mirrors that with an in-memory
overlay of what the proposal itself has done to each path so far:
`{:present, contents}` after a `write_file` or `edit_file`, `:absent` after a
`delete_file`, and no entry for a path the proposal has not touched, in which
case the file on disk is the truth. Nothing is written to disk.

So if a proposal holds two edits to one file, the second is checked against
the result of the first, not against the file on disk. The overlay is only as
good as its model: a `run_command` can change files in ways validation
cannot predict, so intents after one are checked against what the proposal's
own file intents imply, not what the command did.

### Which claims can be evaluated

A claim is accepted only if its condition applies to the kind of intent it
cites. This table mirrors the pairs `EffectApplicator` can evaluate:

| Condition | Source intent |
|---|---|
| `match_count_greater_than` | `grep`, `glob` |
| `match_count_equals` | `grep` |
| `exit_code_equals` | `run_command` |

Any other pair is rejected at validation, because it could never be
evaluated. If a pair is added to the applicator, it must be added here too.

---

## Applying: `EffectApplicator`

`EffectApplicator.apply(intent, prior_results, project_dir)` re-runs the path
check immediately before touching the filesystem. This time it follows every
symlink that exists right now (`IntentPaths.resolved_violation/2`) and
refuses a path that is relative, contains `..`, has too many levels of
links, or resolves outside the project. The re-check narrows the window for
a path to escape the project but does not close it (see T2 in the
[threat model](threat_model.md)).

Then each effect does its own checks: `write_file` fails if the file exists,
`edit_file` re-reads the file and reruns `Current.Edit.replace/4`,
`run_command` fails if `cmd` is not in the configured `allowed_commands` list
(empty by default, so every command is denied) or the executable can't be
found, and a `claim` is
evaluated against the results of the intents before it. A false claim fails
the workflow, and so does any effect that returns `{:error, reason}`.

---

## Events

There is no validator that inspects an event's fields. Instead:

- The set of event types is closed. `Current.Event.valid?/1` is true only for
  the structs listed in `Current.Event.modules/0`.
- Fields are enforced by each struct's `@enforce_keys`.
- Events are read back through `Current.Event.Schema.upcast/1`, which
  migrates an on-disk event to the current shape one version at a time. It
  raises `ArgumentError` for an unknown struct, `UpcastError` when a version
  has no migration, and `FutureVersionError` when the log was written by
  newer code. See [event.md](event.md).
- `WorkflowReducer.apply_event/2` rejects an event that is not a legal next
  step: `{:error, {:invalid_transition, status, event_module}}`, or
  `{:error, {:workflow_id_mismatch, expected, got}}`.

## The log

A commit is accepted only if its index is exactly one past the current head
and its `previous_hash` matches the head's hash. The log refuses to start if
the chain is broken, if the first segment is not number 1, or if a segment
is missing. See the [commit log notes](commit_log_design_notes.md).


