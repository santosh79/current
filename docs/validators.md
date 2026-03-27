### Validators

### Proposal

```elixir
defmodule Current.Proposal.Validator do
  alias Current.Proposal
  alias Current.Intent
  alias Current.Intent.Validator, as: IntentValidator

  def validate(%Proposal{} = proposal) do
    with :ok <- Current.Id.validate(proposal.id),
         :ok <- Current.Id.validate(proposal.workflow_id),
         :ok <- validate_intents(proposal.intents),
         :ok <- validate_justification(proposal.justification),
         :ok <- validate_claims(proposal.claims),
         :ok <- validate_dependencies(proposal.dependencies) do
      :ok
    end
  end

  defp validate_intents(intents) when is_list(intents) and length(intents) > 0 do
    if Enum.all?(intents, &match?(%Intent{}, &1)) do
      validate_each_intent(intents)
    else
      {:error, :invalid_intents}
    end
  end

  defp validate_intents(_), do: {:error, :invalid_intents}

  defp validate_each_intent(intents) do
    Enum.reduce_while(intents, :ok, fn intent, :ok ->
      case IntentValidator.validate(intent) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_intent, intent.id, reason}}}
      end
    end)
  end

  defp validate_justification(nil), do: :ok
  defp validate_justification(j) when is_binary(j), do: :ok
  defp validate_justification(_), do: {:error, :invalid_justification}

  defp validate_claims(nil), do: :ok
  defp validate_claims(claims) when is_list(claims) do
    if Enum.all?(claims, &is_binary/1), do: :ok, else: {:error, :invalid_claims}
  end
  defp validate_claims(_), do: {:error, :invalid_claims}

  defp validate_dependencies(nil), do: :ok
  defp validate_dependencies(deps) when is_list(deps) do
    if Enum.all?(deps, &is_binary/1), do: :ok, else: {:error, :invalid_dependencies}
  end
  defp validate_dependencies(_), do: {:error, :invalid_dependencies}
end
```

#### Intent

```elixir
defmodule Current.Intent.Validator do
  alias Current.Intent

  @valid_types [
    :file_patch,
    :write_file,
    :delete_file,
    :run_command,
    :read_file,
    :glob,
    :grep,
    :claim,
    :report
  ]

  def validate(%Intent{} = intent) do
    with :ok <- Current.Id.validate(intent.id),
         :ok <- Current.Id.validate(intent.proposal_id),
         :ok <- validate_type(intent.type),
         :ok <- validate_payload(intent) do
      :ok
    end
  end

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_payload(%Intent{type: :file_patch, payload: %{path: p, diff: d}})
       when is_binary(p) and is_binary(d),
       do: :ok

  defp validate_payload(%Intent{type: :write_file, payload: %{path: p, content: c}})
       when is_binary(p) and is_binary(c),
       do: :ok

  defp validate_payload(%Intent{type: :delete_file, payload: %{path: p}})
       when is_binary(p),
       do: :ok

  defp validate_payload(%Intent{type: :run_command, payload: %{cmd: cmd}})
       when is_list(cmd),
       do: :ok

  defp validate_payload(%Intent{type: :read_file, payload: %{path: p}})
       when is_binary(p),
       do: :ok

  defp validate_payload(%Intent{type: :glob, payload: %{pattern: p}})
       when is_binary(p),
       do: :ok

  defp validate_payload(%Intent{type: :grep, payload: %{pattern: p}})
       when is_binary(p),
       do: :ok

  defp validate_payload(%Intent{type: :claim, payload: %{value: v}})
       when is_binary(v),
       do: :ok

  defp validate_payload(%Intent{type: :report, payload: %{data: _}}),
       do: :ok

  defp validate_payload(_), do: {:error, :invalid_payload}
end
```

#### Artifact

```elixir
defmodule Current.Artifact.Validator do
  alias Current.Artifact

  @valid_types [
    :file_patch_result,
    :command_result,
    :test_result,
    :read_result,
    :claim_result,
    :report,
    :manifest
  ]

  def validate(%Artifact{} = artifact) do
    with :ok <- Current.Id.validate(artifact.id),
         :ok <- Current.Id.validate(artifact.workflow_id),
         :ok <- validate_type(artifact.type),
         :ok <- validate_name(artifact.name),
         :ok <- validate_storage(artifact.storage),
         :ok <- validate_metadata(artifact.metadata),
         :ok <- validate_timestamp(artifact.timestamp) do
      :ok
    end
  end

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_name(nil), do: :ok
  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_storage(%{backend: :filesystem, path: p})
       when is_binary(p) and byte_size(p) > 0,
       do: :ok
  defp validate_storage(_), do: {:error, :invalid_storage}

  defp validate_metadata(metadata) when is_map(metadata) do
    case metadata do
      %{bytes: bytes} when not is_integer(bytes) or bytes < 0 ->
        {:error, :invalid_metadata}
      %{content_type: ct} when not is_binary(ct) ->
        {:error, :invalid_metadata}
      _ ->
        :ok
    end
  end
  defp validate_metadata(_), do: {:error, :invalid_metadata}

  defp validate_timestamp(%DateTime{}), do: :ok
  defp validate_timestamp(_), do: {:error, :invalid_timestamp}
end
```

#### Event

```elixir
defmodule Current.Event.Validator do
  alias Current.Event

  @valid_types [
    :task_submitted,
    :workflow_created,
    :workflow_started,
    :proposal_produced,
    :approval_requested,
    :proposal_accepted,
    :proposal_rejected,
    :intent_proposed,
    :intent_validated,
    :intent_rejected,
    :effect_applied,
    :effect_failed,
    :artifact_produced,
    :claim_verified,
    :workflow_artifact_assembled,
    :workflow_completed,
    :workflow_failed
  ]

  def validate(%Event{} = event) do
    with :ok <- Current.Id.validate(event.id),
         :ok <- Current.Id.validate(event.workflow_id),
         :ok <- validate_type(event.type),
         :ok <- validate_data(event),
         :ok <- validate_timestamp(event.timestamp) do
      :ok
    end
  end

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_timestamp(%DateTime{}), do: :ok
  defp validate_timestamp(_), do: {:error, :invalid_timestamp}

  defp validate_data(%Event{type: :task_submitted, data: %{task: task}})
       when is_binary(task),
       do: :ok

  defp validate_data(%Event{type: :workflow_created, data: %{workflow_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :workflow_started, data: %{workflow_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :proposal_produced, data: %{proposal_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :approval_requested, data: %{proposal_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :proposal_accepted, data: %{proposal_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :proposal_rejected, data: %{proposal_id: id, reason: reason}})
       when is_binary(id) and is_binary(reason),
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

  defp validate_data(%Event{type: :artifact_produced, data: %{artifact_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :claim_verified, data: %{claim: claim, result: result}})
       when is_binary(claim) and result in [:ok, :error],
       do: :ok

  defp validate_data(%Event{type: :workflow_artifact_assembled, data: %{workflow_artifact_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :workflow_completed, data: %{workflow_id: id}})
       when is_binary(id),
       do: :ok

  defp validate_data(%Event{type: :workflow_failed, data: %{workflow_id: id, reason: reason}})
       when is_binary(id) and is_binary(reason),
       do: :ok

  defp validate_data(_), do: {:error, :invalid_data}
end
```

