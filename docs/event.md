# What is an Event?

## Definition

An **Event** is:

> **An immutable, typed record of something that has already happened in the runtime.**

If an intent is a proposal, an event is a fact.

An event does not describe what *should* happen.  
It records what *did* happen.

---

## Invariants (Must Always Hold)

The following must always hold for any valid event:

1. **Immutable**
   - An event must never be modified after it is recorded.
   - Corrections must be expressed as new events, not edits to old ones.

2. **Serializable**
   - An event must be representable as data (e.g. JSON, Erlang term).
   - It must not contain executable code.

3. **Typed**
   - Every event must belong to a predefined, closed set of event types.
   - Arbitrary or free-form event types are not allowed.

4. **Past-Tense Only**
   - An event must describe something that has already occurred.
   - It must never describe a proposed or hypothetical action.

5. **Context-Bound**
   - Every event must be attributable to a specific task, step, or runtime action.

6. **Append-Only**
   - Events are only added to the log.
   - Existing events must never be deleted or rewritten.

7. **Replayable**
   - Events must contain enough information to support deterministic state reconstruction.

---

## Canonical Representation (System Form)

An event should be representable as a structured value.

Example:

```elixir
%Current.Event{
  type: :intent_validated,
  data: %{
    intent_id: "intent_123",
    validation_result: :ok
  },
  context: %{
    task_id: "task_123",
    step_id: "implement_auth",
    run_id: "run_456"
  },
  timestamp: ~U[2026-03-21 15:00:00Z]
}
```

---

### Struct Definition

```elixir
defmodule Current.Event do
  @enforce_keys [:type, :data, :context, :timestamp]
  defstruct [
    :type,
    :data,
    :context,
    :timestamp
  ]

  @type type ::
          :task_submitted
          | :step_scheduled
          | :step_started
          | :intent_proposed
          | :intent_validated
          | :intent_rejected
          | :effect_applied
          | :effect_failed
          | :claim_verified
          | :step_completed
          | :step_failed
          | :pipeline_completed

  @type t :: %__MODULE__{
          type: type(),
          data: map(),
          context: %{
            task_id: String.t(),
            step_id: String.t() | nil,
            run_id: String.t()
          },
          timestamp: DateTime.t()
        }
end
```

---


### Validation Rules

Every event must pass validation before it can be appended to the event log.

```elixir
defmodule Current.Event.Validator do
  alias Current.Event

  @valid_types [
    :task_submitted,
    :step_scheduled,
    :step_started,
    :intent_proposed,
    :intent_validated,
    :intent_rejected,
    :effect_applied,
    :effect_failed,
    :claim_verified,
    :step_completed,
    :step_failed,
    :pipeline_completed
  ]

  def validate(%Event{} = event) do
    with :ok <- validate_type(event.type),
         :ok <- validate_data(event),
         :ok <- validate_context(event.context),
         :ok <- validate_timestamp(event.timestamp) do
      :ok
    end
  end

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_context(%{task_id: task_id, run_id: run_id})
       when is_binary(task_id) and is_binary(run_id),
       do: :ok

  defp validate_context(_), do: {:error, :invalid_context}

  defp validate_timestamp(%DateTime{}), do: :ok
  defp validate_timestamp(_), do: {:error, :invalid_timestamp}

  defp validate_data(%Event{type: :task_submitted, data: %{task: task}})
       when is_binary(task),
       do: :ok

  defp validate_data(%Event{type: :step_scheduled, data: %{step_id: step_id}})
       when is_binary(step_id),
       do: :ok

  defp validate_data(%Event{type: :step_started, data: %{step_id: step_id}})
       when is_binary(step_id),
       do: :ok

  defp validate_data(%Event{type: :intent_proposed, data: %{intent_ids: ids}})
       when is_list(ids),
       do: :ok

  defp validate_data(%Event{type: :intent_validated, data: %{intent_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :intent_rejected, data: %{intent_id: id, reason: reason}})
       when is_binary(id) and is_binary(reason),
       do: :ok

  defp validate_data(%Event{type: :effect_applied, data: %{intent_id: id, result: _}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :effect_failed, data: %{intent_id: id, reason: reason}})
       when is_binary(id) and is_binary(reason),
       do: :ok

  defp validate_data(%Event{type: :claim_verified, data: %{claim: claim, result: result}})
       when is_binary(claim) and result in [:ok, :error],
       do: :ok

  defp validate_data(%Event{type: :step_completed, data: %{step_id: step_id}})
       when is_binary(step_id),
       do: :ok

  defp validate_data(%Event{type: :step_failed, data: %{step_id: step_id, reason: reason}})
       when is_binary(step_id) and is_binary(reason),
       do: :ok

  defp validate_data(%Event{type: :pipeline_completed, data: %{run_id: run_id}})
       when is_binary(run_id),
       do: :ok

  defp validate_data(_), do: {:error, :invalid_data}
end
```

Validation enforces:
- type must be from a closed set
- data must match the event type
- context must be present and well-formed
- timestamp must be present and valid

If validation fails, the event must not be appended to the event log.

---

Minimum required fields:
- type — atom identifying the intent kind
- payload — structured data required for execution
- context — origin metadata
- timestamp — when the event occurred


---

Let’s break that down carefully.

---

## 1. Immutable

An event is a permanent fact in the system.

Once recorded, it must not change.

If the runtime makes a mistake, the fix is not:

> "edit the old event"

The fix is:

> "append a new event that corrects or supersedes it"

This is the foundation of auditability and replay.