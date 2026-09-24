defmodule Current.CLI.Render do
  @moduledoc """
  Turns the data returned by Current.Inspector into terminal text.

  Pure functions from data to strings, so the output can be tested
  without a running node. Nothing here reads from Current.
  """

  alias Current.{Event, Intent}
  alias Current.Error.{ProposalProductionError, ValidationError}
  alias Current.EventStore.Entry

  @short_hex 12

  ## current plan

  def plan_submitted(task_id) do
    """
    Task submitted
      task     #{task_id}
      mode     plan

      Ctrl-C detaches; the workflow carries on in the runtime.
      Follow it with: current events #{short(task_id)}
    """
  end

  def plan_outcome(%{entries: entries, workflow_id: workflow_id} = view) do
    events = Enum.map(entries, & &1.event)
    root = project_dir(view)
    produced = find(events, Event.ProposalProduced)

    [
      if(root, do: ["", "Project  #{root}"]),
      if(produced, do: proposal_summary(produced, root)),
      "",
      steps(events, produced, root),
      "",
      "MODE: PLAN",
      effects_line(events),
      "",
      "Inspect",
      "  current events   #{short(workflow_id)}",
      if(produced, do: "  current proposal #{short(produced.proposal.id)}"),
      if(produced && produced.raw_output_blob_id,
        do: "  current artifact #{short(produced.raw_output_blob_id)}   (raw model output)"
      )
    ]
    |> lines()
  end

  defp proposal_summary(%Event.ProposalProduced{proposal: proposal} = produced, root) do
    [
      "",
      "Agent produced proposal",
      "  proposal #{proposal.id}",
      if(produced.raw_output_blob_id, do: "  raw      #{produced.raw_output_blob_id}"),
      if(present?(proposal.justification), do: ["", indent(proposal.justification, 2)]),
      "",
      "PROPOSED",
      "",
      proposal.intents
      |> Enum.with_index(1)
      |> Enum.map(fn {intent, n} ->
        {kind, detail} = describe(intent, root)

        "  #{String.pad_leading(Integer.to_string(n), 2)}  #{String.pad_trailing(kind, 12)} #{detail}"
      end),
      if(list_present?(proposal.claims),
        do: ["", "  Claims", Enum.map(proposal.claims, &"    - #{&1}")]
      )
    ]
  end

  defp steps(events, produced, root) do
    already_explained? =
      find(events, Event.ProposalProductionFailed) || find(events, Event.ProposalValidationFailed)

    [
      if(produced, do: "✓ Proposal decoded"),
      case find(events, Event.ProposalProductionFailed) do
        %{error: error} ->
          [
            "✗ Proposal production failed",
            "    #{ProposalProductionError.message(error)}",
            case error do
              %ProposalProductionError{raw_output_blob_id: id} when is_binary(id) ->
                "    raw  #{id}"

              _ ->
                nil
            end
          ]

        nil ->
          nil
      end,
      if(find(events, Event.ProposalValidated), do: "✓ Proposal validated"),
      case find(events, Event.ProposalValidationFailed) do
        %{proposal: proposal, error: %ValidationError{} = error} ->
          ["✗ Proposal validation failed", validation_error(proposal, error, root, 4)]

        nil ->
          nil
      end,
      case terminal_event(events) do
        %Event.WorkflowCompleted{} -> "✓ Workflow completed"
        %Event.WorkflowFailed{} when already_explained? != nil -> "✗ Workflow failed"
        %Event.WorkflowFailed{reason: reason} -> "✗ Workflow failed: #{reason}"
        %Event.WorkflowAbandoned{reason: reason} -> "✗ Workflow abandoned: #{reason}"
        nil -> nil
      end
    ]
  end

  defp effects_line(events) do
    applied = Enum.count(events, &match?(%Event.EffectApplied{}, &1))
    "#{applied} #{if applied == 1, do: "effect", else: "effects"} executed."
  end

  ## current status

  def status(health) do
    [
      "Current #{health.version} · #{health.node}",
      "runtime #{health.status}",
      "  WAL head  #{health.wal_head}",
      "  builder   #{module_name(health.proposal_builder)}",
      "  client    #{module_name(health.llm_client)}",
      "  model     #{health.model || "client default"}",
      if(health.llm_proposal_timeout_ms,
        do: "  timeout   #{div(health.llm_proposal_timeout_ms, 1000)}s"
      )
    ]
    |> lines()
  end

  defp module_name(nil), do: "(not configured)"
  defp module_name(mod) when is_atom(mod), do: inspect(mod)
  defp module_name(other), do: to_string(other)

  ## current events

  def events(%{entries: entries} = view) do
    root = project_dir(view)
    header = "#{pad("POS", 6)}#{pad("EVENT", 28)}#{pad("TIME (UTC)", 14)}DETAIL"

    [
      "Workflow  #{view.workflow_id}",
      if(view.task, do: "Task      #{view.task.id}"),
      if(root, do: "Project   #{root}"),
      "Status    #{view.status} (#{view.mode} mode)",
      if(entries != [], do: "Date      #{entries |> hd() |> timestamp() |> DateTime.to_date()}"),
      "",
      header,
      String.duplicate("─", 72),
      Enum.map(entries, fn %Entry{position: position, event: event} = entry ->
        String.trim_trailing(
          "#{pad(Integer.to_string(position), 6)}#{pad(event_name(event), 28)}" <>
            "#{pad(time(timestamp(entry)), 14)}#{truncate(event_detail(event, root), 60)}"
        )
      end),
      case find(Enum.map(entries, & &1.event), Event.ProposalProduced) do
        %{proposal: proposal} -> ["", "Inspect", "  current proposal #{short(proposal.id)}"]
        nil -> nil
      end
    ]
    |> lines()
  end

  defp event_detail(%Event.TaskCreated{mode: mode, input: input}, _root),
    do: "#{mode} · #{inspect(input)}"

  defp event_detail(%Event.ProposalProduced{proposal: proposal}, _root) do
    count = length(proposal.intents)
    "proposal #{short(proposal.id)} · #{count} #{if count == 1, do: "intent", else: "intents"}"
  end

  defp event_detail(
         %Event.ProposalValidationFailed{error: %ValidationError{reason: reason}},
         _root
       ),
       do: reason

  defp event_detail(%Event.ProposalProductionFailed{error: error}, _root),
    do: ProposalProductionError.message(error)

  defp event_detail(%Event.EffectApplied{intent: intent}, root), do: describe_inline(intent, root)

  defp event_detail(%Event.EffectFailed{intent: intent, reason: reason}, root),
    do: "#{describe_inline(intent, root)}: #{to_text(reason)}"

  defp event_detail(%Event.WorkflowFailed{reason: reason}, _root), do: to_text(reason)
  defp event_detail(%Event.WorkflowAbandoned{reason: reason}, _root), do: to_text(reason)
  defp event_detail(%Event.ModeInvalid{mode: mode}, _root), do: inspect(mode)
  defp event_detail(_event, _root), do: ""

  ## current proposal

  def proposal(%{proposal: proposal} = view) do
    root = view.project_dir

    [
      "Proposal  #{proposal.id}",
      "Workflow  #{view.workflow_id}",
      if(root, do: "Project   #{root}"),
      "Status    #{view.status} (#{view.mode} mode)",
      if(view.raw_output_blob_id, do: "Raw       #{view.raw_output_blob_id}   (model output)"),
      if(present?(proposal.justification),
        do: ["", "Justification", indent(proposal.justification, 2)]
      ),
      "",
      "Intents",
      proposal.intents
      |> Enum.with_index(1)
      |> Enum.map(fn {intent, n} -> intent_block(intent, n, proposal.intents, root) end),
      if(list_present?(proposal.claims),
        do: ["", "Claims", Enum.map(proposal.claims, &"  - #{&1}")]
      ),
      if(list_present?(proposal.dependencies),
        do: ["", "Dependencies", Enum.map(proposal.dependencies, &"  - #{&1}")]
      ),
      if(view.validation_error,
        do: [
          "",
          "✗ Validation failed",
          validation_error(proposal, view.validation_error, root, 2)
        ]
      ),
      case artifact_ids(proposal) do
        [] -> nil
        [id | _] -> ["", "View an artifact:  current artifact #{short(id)}"]
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

  defp fields(%Intent.ReadFile{path: p}, _, root), do: [{"path", rel(p, root)}]
  defp fields(%Intent.DeleteFile{path: p}, _, root), do: [{"path", rel(p, root)}]

  defp fields(%Intent.FilePatch{path: p, diff_artifact_id: id}, _, root),
    do: [{"path", rel(p, root)}, {"diff", id}]

  defp fields(%Intent.WriteFile{path: p, contents_artifact_id: id}, _, root),
    do: [{"path", rel(p, root)}, {"contents", id}]

  defp fields(%Intent.RunCommand{cmd: cmd, args: args}, _, _root),
    do: [{"command", Enum.join([cmd | args || []], " ")}]

  defp fields(%Intent.Grep{pattern: pattern, paths: paths}, _, root),
    do: [
      {"pattern", inspect(pattern)},
      {"paths", Enum.map_join(paths || [], ", ", &rel(&1, root))}
    ]

  defp fields(%Intent.Glob{pattern: pattern, base_dir: base_dir}, _, root),
    do: [{"pattern", inspect(pattern)}, {"base_dir", rel(base_dir, root)}]

  defp fields(%Intent.Claim{} = claim, intents, _root) do
    [
      {"statement", inspect(claim.statement)},
      if(claim.expected != nil, do: {"expected", inspect(claim.expected)}),
      if(claim.evidence, do: {"evidence", evidence(claim.evidence, intents)})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp fields(%Intent.Report{summary: summary}, _, _root), do: [{"summary", summary || ""}]
  defp fields(_intent, _, _root), do: []

  defp evidence(evidence, intents) do
    source =
      case Enum.find_index(intents, &(&1.id == Map.get(evidence, :source_intent_id))) do
        nil -> "intent #{inspect(Map.get(evidence, :source_intent_id))}"
        index -> "intent #{index + 1}"
      end

    "#{source} · #{Map.get(evidence, :condition)} #{inspect(Map.get(evidence, :value))}"
  end

  defp artifact_ids(proposal) do
    Enum.flat_map(proposal.intents, fn
      %Intent.FilePatch{diff_artifact_id: id} -> [id]
      %Intent.WriteFile{contents_artifact_id: id} -> [id]
      _ -> []
    end)
  end

  ## Errors

  def lookup_error(kind, id, :not_found), do: "no #{kind} matches #{id}"

  def lookup_error(_kind, id, :prefix_too_short),
    do: "#{id} is too short to look up; give at least 4 hex digits"

  def lookup_error(kind, id, {:ambiguous, ids}) do
    lines(["#{id} matches #{length(ids)} #{kind}s:", Enum.map(ids, &"  #{&1}")])
  end

  def lookup_error(kind, id, reason), do: "could not read #{kind} #{id}: #{inspect(reason)}"

  ## Shared

  defp validation_error(proposal, %ValidationError{} = error, root, indent_by) do
    at =
      case Enum.find_index(proposal.intents, &(&1.id == error.intent_id)) do
        nil ->
          "intent #{error.intent_id}"

        index ->
          {kind, detail} = describe(Enum.at(proposal.intents, index), root)
          "at intent #{index + 1}: #{kind} #{detail}"
      end

    pad = String.duplicate(" ", indent_by)

    [
      pad <> at,
      "#{pad}reason: #{error.reason}",
      if(error.details not in [nil, %{}], do: "#{pad}details: #{inspect(error.details)}")
    ]
  end

  defp describe(%Intent.ReadFile{path: path}, root), do: {"ReadFile", rel(path, root)}
  defp describe(%Intent.DeleteFile{path: path}, root), do: {"DeleteFile", rel(path, root)}

  defp describe(%Intent.WriteFile{path: path, contents_artifact_id: id}, root),
    do: {"WriteFile", "#{rel(path, root)}  (contents #{short(id)})"}

  defp describe(%Intent.FilePatch{path: path, diff_artifact_id: id}, root),
    do: {"FilePatch", "#{rel(path, root)}  (diff #{short(id)})"}

  defp describe(%Intent.RunCommand{cmd: cmd, args: args}, _root),
    do: {"RunCommand", Enum.join([cmd | args || []], " ")}

  defp describe(%Intent.Grep{pattern: pattern, paths: paths}, root),
    do: {"Grep", "#{inspect(pattern)} in #{Enum.map_join(paths || [], ", ", &rel(&1, root))}"}

  defp describe(%Intent.Glob{pattern: pattern, base_dir: base_dir}, root),
    do: {"Glob", "#{inspect(pattern)} under #{rel(base_dir, root)}"}

  defp describe(%Intent.Claim{statement: statement}, _root), do: {"Claim", inspect(statement)}
  defp describe(%Intent.Report{summary: summary}, _root), do: {"Report", summary || ""}
  defp describe(%{__struct__: mod}, _root), do: {mod |> Module.split() |> List.last(), ""}

  defp describe_inline(intent, root) do
    {kind, detail} = describe(intent, root)
    String.trim("#{kind} #{detail}")
  end

  defp project_dir(%{task: %{project_dir: dir}}) when is_binary(dir), do: dir
  defp project_dir(_view), do: nil

  # Paths in a durable proposal are absolute (IntentPaths.absolutize/2);
  # show them relative to the project when they're inside it.
  defp rel(path, root) when is_binary(path) and is_binary(root), do: Path.relative_to(path, root)
  defp rel(path, _root) when is_binary(path), do: path
  defp rel(path, _root), do: inspect(path)

  @doc "An id shortened to a prefix that the inspectors accept back."
  def short("sha256:" <> hex), do: "sha256:" <> String.slice(hex, 0, @short_hex)
  def short(id), do: to_string(id)

  defp event_name(%{__struct__: mod}), do: mod |> Module.split() |> List.last()

  defp timestamp(%Entry{event: event, inserted_at: inserted_at}),
    do: Map.get(event, :timestamp) || inserted_at

  defp time(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_time() |> Time.to_string()

  defp time(_), do: ""

  defp find(events, module), do: Enum.find(events, &(&1.__struct__ == module))

  defp terminal_event(events) do
    Enum.find(events, fn event ->
      match?(%Event.WorkflowCompleted{}, event) or match?(%Event.WorkflowFailed{}, event) or
        match?(%Event.WorkflowAbandoned{}, event)
    end)
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
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp list_present?(value), do: is_list(value) and value != []

  # Nested lists of lines (nils dropped) -> one string.
  defp lines(parts), do: parts |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n")
end
