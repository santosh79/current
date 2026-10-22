defmodule Current.CLI.Render do
  @moduledoc """
  Turns what the runtime's HTTP API returns into terminal text.

  The input is the API's JSON, decoded: maps with string keys, atoms as
  strings, and every struct a map whose `"type"` is the last part of its
  module name (`"EffectApplied"`, `"EditFile"`; see `Current.HTTP.Encode`).
  Nothing here knows the runtime's own types, so the CLI is a client like
  any other.

  Pure functions from data to strings, so the output can be tested
  without a running runtime. Nothing here talks to Current.
  """

  @short_hex 12

  ## current plan / run / apply

  def task_submitted(task_id, mode, model) do
    """
    Task submitted
      task     #{task_id}
      mode     #{mode}
      model    #{model}

      Ctrl-C detaches; the workflow carries on in the runtime.
      Follow it with: current events #{short(task_id)}
    """
  end

  def outcome(%{"entries" => entries, "workflow_id" => workflow_id} = view) do
    events = Enum.map(entries, & &1["event"])
    root = project_dir(view)
    # With revisions a workflow holds several proposals; what is shown is
    # the latest.
    produced = find_last(events, "ProposalProduced")

    [
      if(root, do: ["", "Project  #{root}"]),
      if(produced, do: proposal_summary(produced, root, events)),
      "",
      steps(events, produced, root),
      claim_checks(entries, root),
      "",
      "MODE: #{view["mode"] |> to_string() |> String.upcase()}",
      effects_line(events),
      if(view["status"] == "waiting_for_approval" and produced != nil,
        do: [
          "",
          "Waiting for approval. Nothing has been applied.",
          "  current review #{short(produced["proposal"]["id"])}",
          "  current approve #{short(produced["proposal"]["id"])} [-m <message>]",
          revise_hint(produced["proposal"]["id"], events)
        ]
      ),
      "",
      "Inspect",
      "  current events   #{short(workflow_id)}",
      if(produced, do: "  current proposal #{short(produced["proposal"]["id"])}"),
      if(produced && produced["raw_output_blob_id"],
        do: "  current artifact #{short(produced["raw_output_blob_id"])}   (raw model output)"
      )
    ]
    |> lines()
  end

  # How many revisions the workflow has left, from its own log: the bound
  # is recorded on WorkflowCreated, the uses on ProposalRevisionRequested.
  defp revisions_left(events) do
    case find(events, "WorkflowCreated") do
      %{"max_revisions" => max} when is_integer(max) ->
        max - Enum.count(events, &(&1["type"] == "ProposalRevisionRequested"))

      _ ->
        nil
    end
  end

  defp revise_hint(proposal_id, events) do
    case revisions_left(events) do
      left when is_integer(left) and left <= 0 ->
        "  (no revisions left: approve or reject)"

      left ->
        "  current revise #{short(proposal_id)} -m <feedback>" <>
          if(left, do: "   (#{plural(left, "revision")} left)", else: "")
    end
  end

  # The reviewer feedback that this proposal answers, if it is a revision.
  defp feedback_for(%{"revises" => revises}, events) when is_binary(revises) do
    Enum.find_value(events, fn
      %{"type" => "ProposalRevisionRequested", "proposal_id" => ^revises, "feedback" => feedback} ->
        feedback

      _ ->
        nil
    end)
  end

  defp feedback_for(_proposal, _events), do: nil

  defp proposal_summary(%{"proposal" => proposal} = produced, root, events) do
    [
      "",
      "Agent produced proposal",
      "  proposal #{proposal["id"]}",
      if((proposal["revision"] || 0) > 0,
        do: "  revision #{proposal["revision"]} (replaces #{short(proposal["revises"])})"
      ),
      if(feedback_for(proposal, events),
        do: ["  feedback", indent(feedback_for(proposal, events), 4)]
      ),
      if(produced["raw_output_blob_id"], do: "  raw      #{produced["raw_output_blob_id"]}"),
      if(present?(proposal["justification"]),
        do: ["", indent(proposal["justification"], 2)]
      ),
      "",
      "PROPOSED",
      "",
      proposal["intents"]
      |> Enum.with_index(1)
      |> Enum.map(fn {intent, n} ->
        {kind, detail} = describe(intent, root)

        "  #{String.pad_leading(Integer.to_string(n), 2)}  #{String.pad_trailing(kind, 12)} #{detail}"
      end),
      if(list_present?(proposal["claims"]),
        do: ["", "  Claims", Enum.map(proposal["claims"], &"    - #{&1}")]
      )
    ]
  end

  defp steps(events, produced, root) do
    production_failed = find_last(events, "ProposalProductionFailed")
    validation_failed = find_last(events, "ProposalValidationFailed")
    revisions = Enum.count(events, &(&1["type"] == "ProposalRevisionRequested"))
    already_explained? = production_failed || validation_failed

    [
      if(produced, do: "✓ Proposal decoded"),
      case production_failed do
        %{"error" => error} ->
          [
            "✗ Proposal production failed",
            "    #{production_message(error)}",
            case error do
              %{"raw_output_blob_id" => id} when is_binary(id) -> "    raw  #{id}"
              _ -> nil
            end
          ]

        nil ->
          nil
      end,
      if(revisions > 0, do: "↻ #{plural(revisions, "revision")} requested"),
      if(find_last(events, "ProposalValidated"), do: "✓ Proposal validated"),
      case validation_failed do
        %{"proposal" => proposal, "error" => %{"type" => "ValidationError"} = error} ->
          ["✗ Proposal validation failed", validation_error(proposal, error, root, 4)]

        _ ->
          nil
      end,
      if(find(events, "ProposalApproved"), do: "✓ Proposal approved"),
      if(find(events, "ProposalRejected"), do: "✗ Proposal rejected"),
      case terminal_event(events) do
        %{"type" => "WorkflowCompleted"} ->
          "✓ Workflow completed"

        %{"type" => "WorkflowFailed"} when already_explained? != nil ->
          "✗ Workflow failed"

        %{"type" => "WorkflowFailed", "reason" => reason} ->
          "✗ Workflow failed: #{to_text(reason)}"

        %{"type" => "WorkflowAbandoned", "reason" => reason} ->
          "✗ Workflow abandoned: #{to_text(reason)}"

        nil ->
          nil
      end
    ]
  end

  defp production_message(%{"message" => message}) when is_binary(message), do: message
  defp production_message(_error), do: "proposal production failed"

  defp effects_line(events) do
    results = for %{"type" => "EffectApplied", "result" => result} <- events, do: result
    verified = Enum.count(results, &match?(%{"type" => "Claim", "verified" => true}, &1))
    unverified = Enum.count(results, &match?(%{"type" => "Claim", "verified" => false}, &1))

    [
      plural(length(results), "effect") <> " executed",
      if(verified > 0, do: plural(verified, "claim") <> " verified"),
      if(unverified > 0, do: plural(unverified, "claim") <> " not verified")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> Kernel.<>(".")
  end

  # Every claim that was checked, with the evidence Current checked it
  # against. The statement is the model's; the evidence line is what
  # actually ran.
  defp claim_checks(entries, root) do
    applied = applied_effects(entries)

    checks =
      for %{"event" => %{"type" => "EffectApplied", "result" => %{"type" => "Claim"} = claim}} <-
            entries do
        [
          "  #{mark(claim)} #{inspect(claim["statement"])}",
          "      " <>
            evidence_text(claim, applied, fn {_pos, intent, _result} ->
              describe_inline(intent, root) <> " ·"
            end)
        ]
      end

    if checks != [], do: ["", "Claim checks", checks]
  end

  ## current status

  @activity_label_width 38

  @doc """
  The lines `current plan` / `current run` print for one item of live
  activity (see Current.API.activity/3): when the model asks to see
  something, then how each request turned out.

      … round 1: the model asked to see 3 things
          ✓ glob lib/*.ex                          1.2 KB
          ✗ read_file .env                         refused: .env is excluded
  """
  @spec activity([map()] | map()) :: [String.t()]
  def activity(items) when is_list(items), do: Enum.flat_map(items, &activity/1)

  def activity(%{"type" => "requested", "round" => round, "entries" => entries}) do
    count = length(entries)

    [
      "  … round #{round}: the model asked to see #{count} #{if count == 1, do: "thing", else: "things"}"
    ]
  end

  def activity(%{"type" => "settled", "entries" => entries}) do
    Enum.map(entries, fn
      %{"status" => "shown", "label" => label, "bytes" => bytes} ->
        "      ✓ #{String.pad_trailing(label, @activity_label_width)} #{activity_size(bytes)}"

      %{"status" => "refused", "label" => label, "error" => error} ->
        "      ✗ #{String.pad_trailing(label, @activity_label_width)} refused: #{error}"
    end)
  end

  defp activity_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp activity_size(bytes), do: "#{:erlang.float_to_binary(bytes / 1024, decimals: 1)} KB"

  @doc "The lines `current status` prints; `url` is where the runtime was reached."
  def status(health, url) do
    [
      "Current #{health["version"]} · #{url}",
      "runtime #{health["status"]}",
      "  WAL head  #{health["wal_head"]}",
      "  builder   #{module_name(health["proposal_builder"])}",
      if(health["llm_proposal_timeout_ms"],
        do: "  timeout   #{div(health["llm_proposal_timeout_ms"], 1000)}s per model call"
      ),
      if(health["llm_task_timeout_ms"],
        do: "            #{div(health["llm_task_timeout_ms"], 1000)}s per task"
      )
    ]
    |> lines()
  end

  # The API gives a module as its atom's name: "Elixir.Current.Foo".
  defp module_name(nil), do: "(not configured)"
  defp module_name(name) when is_binary(name), do: String.replace_prefix(name, "Elixir.", "")
  defp module_name(other), do: to_string(other)

  ## current events

  def events(%{"entries" => entries} = view) do
    root = project_dir(view)
    applied = applied_effects(entries)
    header = "#{pad("POS", 6)}#{pad("EVENT", 28)}#{pad("TIME (UTC)", 14)}DETAIL"

    [
      "Workflow  #{view["workflow_id"]}",
      if(view["task"], do: "Task      #{view["task"]["id"]}"),
      if(root, do: "Project   #{root}"),
      "Status    #{view["status"]} (#{view["mode"]} mode)",
      case entries do
        [first | _] -> date_line(timestamp(first))
        [] -> nil
      end,
      "",
      header,
      String.duplicate("─", 72),
      Enum.map(entries, fn %{"position" => position, "event" => event} = entry ->
        String.trim_trailing(
          "#{pad(Integer.to_string(position), 6)}#{pad(event_name(event), 28)}" <>
            "#{pad(time(timestamp(entry)), 14)}#{truncate(table_detail(event, applied, root), 60)}"
        )
      end),
      case find_last(Enum.map(entries, & &1["event"]), "ProposalProduced") do
        %{"proposal" => proposal} ->
          ["", "Inspect", "  current proposal #{short(proposal["id"])}"]

        nil ->
          nil
      end
    ]
    |> lines()
  end

  defp date_line(%DateTime{} = dt), do: "Date      #{DateTime.to_date(dt)}"
  defp date_line(_), do: nil

  # Effects show what they returned, not just what they were asked to
  # do. A claim's evidence points at the effect it was checked against
  # by that effect's position in the table.
  defp table_detail(
         %{"type" => "EffectApplied", "intent" => intent, "result" => result},
         applied,
         root
       ),
       do:
         effect_detail(intent, result, applied, root, fn {pos, _intent, _result} -> "##{pos}" end)

  defp table_detail(event, _applied, root), do: event_detail(event, root)

  defp effect_detail(_intent, %{"type" => "Claim"} = claim, applied, _root, source_label),
    do:
      "Claim #{mark(claim)} #{evidence_text(claim, applied, source_label)} · #{inspect(claim["statement"])}"

  defp effect_detail(intent, %{"type" => "Command", "exit_code" => code}, _applied, root, _),
    do: "#{describe_inline(intent, root)} · exit #{code}"

  defp effect_detail(intent, %{"type" => "Grep", "match_count" => n}, _applied, root, _),
    do: "#{describe_inline(intent, root)} · #{plural(n, "match", "matches")}"

  defp effect_detail(intent, %{"type" => "Glob", "match_count" => n}, _applied, root, _),
    do: "#{describe_inline(intent, root)} · #{plural(n, "match", "matches")}"

  defp effect_detail(intent, _result, _applied, root, _), do: describe_inline(intent, root)

  # intent id => {position, intent, result} for every applied effect.
  defp applied_effects(entries) do
    for %{
          "position" => pos,
          "event" => %{"type" => "EffectApplied", "intent" => intent, "result" => result}
        } <- entries,
        into: %{},
        do: {intent["id"], {pos, intent, result}}
  end

  defp mark(%{"verified" => true}), do: "✓"
  defp mark(_claim), do: "✗"

  # What the claim was checked against, built from the source effect's
  # own recorded result. Falls back to the applicator's reason if the
  # source isn't in this history.
  defp evidence_text(%{"evidence" => evidence, "reason" => reason}, applied, source_label) do
    with %{"source_intent_id" => source_id, "condition" => condition, "value" => expected} <-
           evidence,
         {_pos, _intent, result} = source <- Map.get(applied, source_id),
         observed when is_binary(observed) <- observed(condition, expected, result) do
      "#{source_label.(source)} #{observed}"
    else
      _ -> reason || ""
    end
  end

  defp observed("exit_code_equals", expected, %{"type" => "Command", "exit_code" => code}),
    do: "exit #{code} (expected #{expected})"

  defp observed("match_count_equals", expected, %{"match_count" => n}),
    do: "#{plural(n, "match", "matches")} (expected #{expected})"

  defp observed("match_count_greater_than", expected, %{"match_count" => n}),
    do: "#{plural(n, "match", "matches")} (expected > #{expected})"

  defp observed(_condition, _expected, _result), do: nil

  defp plural(n, singular, plural \\ nil),
    do: "#{n} #{if n == 1, do: singular, else: plural || singular <> "s"}"

  defp event_detail(%{"type" => "TaskCreated", "mode" => mode, "input" => input}, _root),
    do: "#{mode} · #{inspect(input)}"

  defp event_detail(%{"type" => "ProposalProduced", "proposal" => proposal}, _root) do
    count = length(proposal["intents"])
    "proposal #{short(proposal["id"])} · #{count} #{if count == 1, do: "intent", else: "intents"}"
  end

  defp event_detail(
         %{
           "type" => "ProposalValidationFailed",
           "error" => %{"type" => "ValidationError"} = error
         },
         _root
       ),
       do: error["reason"]

  defp event_detail(%{"type" => "ProposalProductionFailed", "error" => error}, _root),
    do: production_message(error)

  defp event_detail(%{"type" => "EffectApplied", "intent" => intent}, root),
    do: describe_inline(intent, root)

  # The claim itself is on the EffectApplied line just above.
  defp event_detail(
         %{"type" => "EffectFailed", "intent" => %{"type" => "Claim"}, "reason" => reason},
         _root
       ),
       do: to_text(reason)

  defp event_detail(%{"type" => "EffectFailed", "intent" => intent, "reason" => reason}, root),
    do: "#{describe_inline(intent, root)}: #{to_text(reason)}"

  defp event_detail(%{"type" => "WorkflowFailed", "reason" => reason}, _root),
    do: to_text(reason)

  defp event_detail(%{"type" => "WorkflowAbandoned", "reason" => reason}, _root),
    do: to_text(reason)

  defp event_detail(%{"type" => "ModeInvalid", "mode" => mode}, _root), do: to_text(mode)

  defp event_detail(
         %{"type" => "ProposalApproved", "metadata" => %{"message" => message}},
         _root
       ),
       do: inspect(message)

  defp event_detail(
         %{"type" => "ProposalRejected", "metadata" => %{"message" => message}},
         _root
       ),
       do: inspect(message)

  defp event_detail(
         %{"type" => "ProposalRevisionRequested", "proposal_id" => id, "feedback" => feedback},
         _root
       ),
       do: "#{short(id)} · #{inspect(feedback)}"

  defp event_detail(_event, _root), do: ""

  ## current proposal

  def proposal(%{"proposal" => proposal} = view) do
    root = view["project_dir"]
    intents = proposal["intents"]

    [
      "Proposal  #{proposal["id"]}",
      "Workflow  #{view["workflow_id"]}",
      if(root, do: "Project   #{root}"),
      "Status    #{view["status"]} (#{view["mode"]} mode)",
      if((proposal["revision"] || 0) > 0,
        do: "Revision  #{proposal["revision"]} (replaces #{short(proposal["revises"])})"
      ),
      if(present?(view["feedback"]),
        do: ["Feedback", indent(view["feedback"], 2)]
      ),
      if(view["current_proposal_id"] && view["current_proposal_id"] != proposal["id"],
        do: "Superseded by #{short(view["current_proposal_id"])}"
      ),
      if(view["raw_output_blob_id"],
        do: "Raw       #{view["raw_output_blob_id"]}   (model output)"
      ),
      if(present?(proposal["justification"]),
        do: ["", "Justification", indent(proposal["justification"], 2)]
      ),
      observed(proposal["observations"] || []),
      "",
      "Intents",
      intents
      |> Enum.with_index(1)
      |> Enum.map(fn {intent, n} -> intent_block(intent, n, intents, root) end),
      if(list_present?(proposal["claims"]),
        do: ["", "Claims", Enum.map(proposal["claims"], &"  - #{&1}")]
      ),
      if(list_present?(proposal["dependencies"]),
        do: ["", "Dependencies", Enum.map(proposal["dependencies"], &"  - #{&1}")]
      ),
      if(view["validation_error"],
        do: [
          "",
          "✗ Validation failed",
          validation_error(proposal, view["validation_error"], root, 2)
        ]
      ),
      case artifact_ids(proposal) do
        [] ->
          nil

        [id | _] ->
          [
            "",
            "View an artifact:  current artifact #{short(id)}",
            "See them all:      current review #{short(proposal["id"])}"
          ]
      end
    ]
    |> lines()
  end

  defp intent_block(intent, n, intents, root) do
    {kind, _} = describe(intent, root)
    rows = fields(intent, intents, root)
    width = rows |> Enum.map(fn {label, _} -> String.length(label) end) |> Enum.max(fn -> 0 end)

    [
      "",
      "  #{n}. #{kind}",
      Enum.map(rows, fn {label, value} -> "     #{pad(label, width + 2)}#{value}" end)
    ]
  end

  defp fields(%{"type" => "ReadFile", "path" => p}, _, root), do: [{"path", rel(p, root)}]
  defp fields(%{"type" => "DeleteFile", "path" => p}, _, root), do: [{"path", rel(p, root)}]

  defp fields(%{"type" => "EditFile", "path" => p} = edit, _, root),
    do:
      [
        {"path", rel(p, root)},
        {"old", edit["old_artifact_id"]},
        {"new", edit["new_artifact_id"]},
        if(edit["replace_all"], do: {"replace_all", "yes"})
      ]
      |> Enum.reject(&is_nil/1)

  defp fields(%{"type" => "WriteFile", "path" => p, "contents_artifact_id" => id}, _, root),
    do: [{"path", rel(p, root)}, {"contents", id}]

  defp fields(%{"type" => "RunCommand", "cmd" => cmd} = intent, _, _root),
    do: [{"command", Enum.join([cmd | intent["args"] || []], " ")}]

  defp fields(%{"type" => "Grep", "pattern" => pattern} = intent, _, root),
    do: [
      {"pattern", inspect(pattern)},
      {"paths", Enum.map_join(intent["paths"] || [], ", ", &rel(&1, root))}
    ]

  defp fields(%{"type" => "Glob", "pattern" => pattern} = intent, _, root),
    do: [{"pattern", inspect(pattern)}, {"base_dir", rel(intent["base_dir"], root)}]

  defp fields(%{"type" => "Claim"} = claim, intents, _root) do
    [
      {"statement", inspect(claim["statement"])},
      if(claim["expected"] != nil, do: {"expected", inspect(claim["expected"])}),
      if(claim["evidence"], do: {"evidence", evidence(claim["evidence"], intents)})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp fields(%{"type" => "Report"} = intent, _, _root),
    do: [{"summary", intent["summary"] || ""}]

  defp fields(_intent, _, _root), do: []

  defp evidence(evidence, intents) do
    source =
      case Enum.find_index(intents, &(&1["id"] == evidence["source_intent_id"])) do
        nil -> "intent #{inspect(evidence["source_intent_id"])}"
        index -> "intent #{index + 1}"
      end

    "#{source} · #{evidence["condition"]} #{inspect(evidence["value"])}"
  end

  defp artifact_ids(proposal) do
    Enum.flat_map(proposal["intents"], fn
      %{"type" => "EditFile", "old_artifact_id" => old, "new_artifact_id" => new} -> [old, new]
      %{"type" => "WriteFile", "contents_artifact_id" => id} -> [id]
      _ -> []
    end)
  end

  ## Errors

  @doc """
  What to say when looking up a `kind` ("proposal", "workflow", ...) by
  `id` failed with `reason`, an error from `Current.CLI.Client`.
  """
  def lookup_error(kind, id, {:api_error, %{code: "not_found"}}), do: "no #{kind} matches #{id}"

  def lookup_error(_kind, id, {:api_error, %{code: "prefix_too_short"}}),
    do: "#{id} is too short to look up; give at least 4 hex digits"

  def lookup_error(kind, id, {:api_error, %{code: "ambiguous_id", details: %{"ids" => ids}}}) do
    lines(["#{id} matches #{length(ids)} #{kind}s:", Enum.map(ids, &"  #{&1}")])
  end

  def lookup_error(kind, id, {:api_error, %{message: message}}),
    do: "could not read #{kind} #{id}: #{message}"

  def lookup_error(kind, id, reason), do: "could not read #{kind} #{id}: #{inspect(reason)}"

  ## Shared

  defp validation_error(proposal, error, root, indent_by) do
    intents = proposal["intents"]

    at =
      case Enum.find_index(intents, &(&1["id"] == error["intent_id"])) do
        nil ->
          "intent #{error["intent_id"]}"

        index ->
          {kind, detail} = describe(Enum.at(intents, index), root)
          "at intent #{index + 1}: #{kind} #{detail}"
      end

    pad = String.duplicate(" ", indent_by)

    [
      pad <> at,
      "#{pad}reason: #{error["reason"]}",
      if(error["details"] not in [nil, %{}],
        do: "#{pad}details: #{JSON.encode!(error["details"])}"
      )
    ]
  end

  defp describe(%{"type" => "ReadFile", "path" => path}, root), do: {"ReadFile", rel(path, root)}

  defp describe(%{"type" => "DeleteFile", "path" => path}, root),
    do: {"DeleteFile", rel(path, root)}

  defp describe(%{"type" => "WriteFile", "path" => path, "contents_artifact_id" => id}, root),
    do: {"WriteFile", "#{rel(path, root)}  (contents #{short(id)})"}

  defp describe(
         %{
           "type" => "EditFile",
           "path" => path,
           "old_artifact_id" => old,
           "new_artifact_id" => new
         },
         root
       ),
       do: {"EditFile", "#{rel(path, root)}  (#{short(old)} → #{short(new)})"}

  defp describe(%{"type" => "RunCommand", "cmd" => cmd} = intent, _root),
    do: {"RunCommand", Enum.join([cmd | intent["args"] || []], " ")}

  defp describe(%{"type" => "Grep", "pattern" => pattern} = intent, root),
    do:
      {"Grep",
       "#{inspect(pattern)} in #{Enum.map_join(intent["paths"] || [], ", ", &rel(&1, root))}"}

  defp describe(%{"type" => "Glob", "pattern" => pattern} = intent, root),
    do: {"Glob", "#{inspect(pattern)} under #{rel(intent["base_dir"], root)}"}

  defp describe(%{"type" => "Claim", "statement" => statement}, _root),
    do: {"Claim", inspect(statement)}

  defp describe(%{"type" => "Report"} = intent, _root), do: {"Report", intent["summary"] || ""}
  defp describe(%{"type" => type}, _root), do: {type, ""}
  defp describe(_intent, _root), do: {"?", ""}

  defp describe_inline(intent, root) do
    {kind, detail} = describe(intent, root)
    String.trim("#{kind} #{detail}")
  end

  defp project_dir(%{"task" => %{"project_dir" => dir}}) when is_binary(dir), do: dir
  defp project_dir(_view), do: nil

  # Paths in a durable proposal are absolute (IntentPaths.absolutize/2);
  # show them relative to the project when they're inside it.
  defp rel(path, root) when is_binary(path) and is_binary(root), do: Path.relative_to(path, root)
  defp rel(path, _root) when is_binary(path), do: path
  defp rel(path, _root), do: inspect(path)

  @doc "An id shortened to a prefix that the API accepts back."
  def short("sha256:" <> hex), do: "sha256:" <> String.slice(hex, 0, @short_hex)
  def short(id), do: to_string(id)

  defp event_name(%{"type" => type}), do: type
  defp event_name(_event), do: "?"

  defp timestamp(entry) do
    parse_time(get_in(entry, ["event", "timestamp"])) ||
      parse_time(entry["inserted_at"])
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp time(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_time() |> Time.to_string()

  defp time(_), do: ""

  defp find(events, type), do: Enum.find(events, &(&1["type"] == type))

  # The latest of its kind, for events that repeat once per revision.
  defp find_last(events, type), do: events |> Enum.filter(&(&1["type"] == type)) |> List.last()

  defp terminal_event(events) do
    Enum.find(
      events,
      &(&1["type"] in ["WorkflowCompleted", "WorkflowFailed", "WorkflowAbandoned"])
    )
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: inspect(value)

  defp truncate(text, max) do
    text = text |> String.split("\n") |> hd()
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp indent(text, n) do
    pad = String.duplicate(" ", n)
    text |> String.trim() |> String.split("\n") |> Enum.map_join("\n", &(pad <> &1))
  end

  defp pad(text, width), do: String.pad_trailing(text, width)

  # What the agent looked at before proposing, one entry per
  # observation: the round it asked in, what it asked and why, and the
  # artifact holding what it was shown (print it with `current
  # artifact`) or why it got nothing.
  defp observed([]), do: nil

  defp observed(observations) do
    [
      "",
      "Observed before proposing",
      Enum.map(observations, &observation/1)
    ]
  end

  defp observation(%{"type" => "Observation"} = observation) do
    [
      "  #{observation["round"] || "?"}. #{asked(observation["intent"])}",
      if(present?(observation["reason"]), do: "       why      #{observation["reason"]}"),
      "       #{settled(observation)}"
    ]
  end

  # A proposal recorded while observations were still listed by record
  # id: say so, and give the id, which `current artifact` can still print.
  defp observation(record_id) when is_binary(record_id),
    do: "  ?. recorded in an older format: #{record_id}"

  defp observation(_other), do: "  ?. unreadable observation"

  defp asked(%{"type" => "ReadFile", "path" => path}), do: "read_file #{path}"

  defp asked(%{"type" => "Glob", "pattern" => pattern, "base_dir" => base_dir}),
    do: "glob #{pattern} in #{base_dir}"

  defp asked(%{"type" => "Grep", "pattern" => pattern, "paths" => paths}),
    do: "grep #{inspect(pattern)} in #{Enum.join(paths, ", ")}"

  defp asked(_intent), do: "?"

  defp settled(%{"status" => "shown", "artifact_id" => artifact_id}),
    do: "shown    #{artifact_id}"

  defp settled(%{"status" => "refused", "error" => error}), do: "refused  #{error}"
  defp settled(%{"status" => status}), do: to_string(status)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp list_present?(value), do: is_list(value) and value != []

  # Nested lists of lines (nils dropped) -> one string.
  defp lines(parts), do: parts |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n")
end
