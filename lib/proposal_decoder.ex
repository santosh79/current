defmodule Current.ProposalDecoder do
  @moduledoc """
  Turns an LLM's raw text response into a Current.Proposal.t() -- the one
  place untrusted model bytes get parsed into Current's typed intent
  language. This module answers "can these bytes be represented as a
  Proposal at all" (JSON shape, known intent types, required fields
  present, references resolvable) -- it does NOT answer "is this Proposal
  acceptable to run"; that's Current.IntentValidator, on the Proposal
  this module hands back.

  Pure: no network calls, no knowledge of the LLM client, never raises.
  The one side effect is Current.BlobStore.put/1 for intent payloads
  carried inline on the wire (diff/contents text) -- everything else
  about talking to a model, and about persisting the raw response for
  provenance, is the caller's (Current.LLMProposalBuilder's) job.

  Wire intents reference each other by an arbitrary caller-chosen `ref`
  string (e.g. a Claim's evidence.source_intent_ref), never by Current's
  real Current.Id.t() values -- the model can't know those in advance.
  This module assigns real ids and resolves refs into them.
  """

  alias Current.{BlobStore, Id, Intent, Proposal}

  @spec decode(String.t(), Current.Id.t()) :: {:ok, Proposal.t()} | {:error, String.t()}
  def decode(raw, workflow_id) when is_binary(raw) do
    proposal_id = Id.generate()

    with {:ok, decoded} <- parse_json(raw),
         {:ok, top} <- require_map(decoded, "top-level response"),
         {:ok, raw_intents} <- require_list(Map.get(top, "intents"), "intents"),
         {:ok, intents} <- decode_intents(raw_intents, proposal_id) do
      {:ok,
       %Proposal{
         id: proposal_id,
         workflow_id: workflow_id,
         intents: intents,
         justification: optional_string(top, "justification"),
         claims: optional_string_list(top, "claims"),
         dependencies: optional_string_list(top, "dependencies")
       }}
    end
  end

  ## --- JSON / shape --------------------------------------------------

  defp parse_json(raw) do
    {:ok, :json.decode(raw)}
  rescue
    _ -> {:error, "response was not valid JSON"}
  end

  defp require_map(%{} = map, _label), do: {:ok, map}
  defp require_map(_other, label), do: {:error, "#{label} must be a JSON object"}

  defp require_list(list, _label) when is_list(list), do: {:ok, list}
  defp require_list(_other, label), do: {:error, "#{label} must be a JSON array"}

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp optional_string_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> if Enum.all?(list, &is_binary/1), do: list, else: nil
      _ -> nil
    end
  end

  ## --- Intents: two-pass decode ---------------------------------------
  # Pass 1 assigns every intent a real id and records ref -> id for any
  # entry that carries a "ref". Pass 2 builds the typed Intent.t()
  # structs, resolving claim evidence.source_intent_ref against that
  # map. Ordering (does the referenced intent precede the claim) is
  # deliberately NOT checked here -- that's IntentValidator's job, once
  # everything is a real Intent.t() carrying a real id.

  defp decode_intents(raw_intents, proposal_id) do
    with {:ok, entries} <- assign_ids(raw_intents) do
      ref_to_id = build_ref_map(entries)
      build_intents(entries, proposal_id, ref_to_id)
    end
  end

  defp assign_ids(raw_intents) do
    raw_intents
    |> Enum.reduce_while({:ok, []}, fn raw_intent, {:ok, acc} ->
      case require_map(raw_intent, "intent") do
        {:ok, map} -> {:cont, {:ok, [{Id.generate(), map} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_ref_map(entries) do
    Enum.reduce(entries, %{}, fn {id, map}, acc ->
      case Map.get(map, "ref") do
        ref when is_binary(ref) -> Map.put(acc, ref, id)
        _ -> acc
      end
    end)
  end

  defp build_intents(entries, proposal_id, ref_to_id) do
    entries
    |> Enum.reduce_while({:ok, []}, fn {id, map}, {:ok, acc} ->
      case build_intent(id, proposal_id, map, ref_to_id) do
        {:ok, intent} -> {:cont, {:ok, [intent | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  ## --- Per-type decode -------------------------------------------------

  defp build_intent(id, proposal_id, %{"type" => "read_file"} = map, _refs) do
    with {:ok, path} <- require_string(map, "path") do
      {:ok, %Intent.ReadFile{id: id, proposal_id: proposal_id, path: path}}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "write_file"} = map, _refs) do
    with {:ok, path} <- require_string(map, "path"),
         {:ok, contents} <- require_string(map, "contents"),
         {:ok, blob_id} <- BlobStore.put(contents) do
      {:ok,
       %Intent.WriteFile{
         id: id,
         proposal_id: proposal_id,
         path: path,
         contents_artifact_id: blob_id
       }}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "delete_file"} = map, _refs) do
    with {:ok, path} <- require_string(map, "path") do
      {:ok, %Intent.DeleteFile{id: id, proposal_id: proposal_id, path: path}}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "file_patch"} = map, _refs) do
    with {:ok, path} <- require_string(map, "path"),
         {:ok, diff} <- require_string(map, "diff"),
         {:ok, blob_id} <- BlobStore.put(diff) do
      {:ok,
       %Intent.FilePatch{
         id: id,
         proposal_id: proposal_id,
         path: path,
         diff_artifact_id: blob_id
       }}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "run_command"} = map, _refs) do
    with {:ok, cmd} <- require_string(map, "cmd"),
         {:ok, args} <- optional_string_list_default(map, "args", []) do
      {:ok, %Intent.RunCommand{id: id, proposal_id: proposal_id, cmd: cmd, args: args}}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "grep"} = map, _refs) do
    with {:ok, pattern} <- require_string(map, "pattern"),
         {:ok, paths} <- require_string_list(map, "paths") do
      {:ok, %Intent.Grep{id: id, proposal_id: proposal_id, pattern: pattern, paths: paths}}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "glob"} = map, _refs) do
    with {:ok, pattern} <- require_string(map, "pattern"),
         {:ok, base_dir} <- optional_string_default(map, "base_dir", ".") do
      {:ok, %Intent.Glob{id: id, proposal_id: proposal_id, pattern: pattern, base_dir: base_dir}}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "claim"} = map, refs) do
    with {:ok, statement} <- require_string(map, "statement"),
         {:ok, evidence} <- decode_evidence(Map.get(map, "evidence"), refs) do
      {:ok,
       %Intent.Claim{id: id, proposal_id: proposal_id, statement: statement, evidence: evidence}}
    end
  end

  defp build_intent(id, proposal_id, %{"type" => "report"} = map, _refs) do
    with {:ok, summary} <- optional_string_default(map, "summary", nil) do
      {:ok, %Intent.Report{id: id, proposal_id: proposal_id, summary: summary}}
    end
  end

  defp build_intent(_id, _proposal_id, %{"type" => other}, _refs),
    do: {:error, "unknown intent type: #{inspect(other)}"}

  defp build_intent(_id, _proposal_id, %{}, _refs),
    do: {:error, "intent missing required field: type"}

  ## --- Claim evidence --------------------------------------------------

  defp decode_evidence(nil, _refs), do: {:ok, nil}

  defp decode_evidence(%{} = evidence, refs) do
    with {:ok, ref} <- require_string(evidence, "source_intent_ref"),
         {:ok, source_intent_id} <- resolve_ref(ref, refs),
         {:ok, condition} <- decode_condition(Map.get(evidence, "condition")),
         {:ok, value} <- require_present(evidence, "value") do
      {:ok, %{source_intent_id: source_intent_id, condition: condition, value: value}}
    end
  end

  defp decode_evidence(_other, _refs), do: {:error, "claim evidence must be a JSON object"}

  defp resolve_ref(ref, refs) do
    case Map.fetch(refs, ref) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "claim evidence references unknown ref: #{inspect(ref)}"}
    end
  end

  # Explicit allowlist, not String.to_atom/1 -- never mint atoms from
  # untrusted model output.
  defp decode_condition("match_count_greater_than"), do: {:ok, :match_count_greater_than}
  defp decode_condition("match_count_equals"), do: {:ok, :match_count_equals}
  defp decode_condition("exit_code_equals"), do: {:ok, :exit_code_equals}
  defp decode_condition(other), do: {:error, "unknown claim condition: #{inspect(other)}"}

  defp require_present(map, key) do
    if Map.has_key?(map, key),
      do: {:ok, Map.get(map, key)},
      else: {:error, "evidence missing required field: #{key}"}
  end

  ## --- Field helpers -----------------------------------------------------

  defp require_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "intent missing required string field: #{key}"}
    end
  end

  defp require_string_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "intent field #{key} must be a list of strings"}

      _ ->
        {:error, "intent missing required list field: #{key}"}
    end
  end

  defp optional_string_list_default(map, key, default) do
    case Map.get(map, key) do
      nil ->
        {:ok, default}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "intent field #{key} must be a list of strings"}

      _ ->
        {:error, "intent field #{key} must be a list of strings"}
    end
  end

  defp optional_string_default(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "intent field #{key} must be a string"}
    end
  end
end
