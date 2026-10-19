defmodule Current.CLI.ReviewMarkdown do
  @moduledoc """
  Renders a review as Markdown, laid out like a pull request: what the
  proposal is and why, then each intent in order with its artifact
  inline -- the old and new text for an EditFile, the new contents for a
  WriteFile.

  The input is the `current.review/v1` document the API serves
  (`GET /v1/proposals/:id/review`, decoded: maps with string keys; see
  `Current.CLI.ReviewJSON` for its shape), so the Markdown is rendered
  from exactly what `current review --json` prints.

  Pure, like Current.CLI.Render: data in, string out.
  """

  alias Current.CLI.Render

  @spec render(map()) :: String.t()
  def render(%{"proposal" => proposal, "workflow" => workflow} = review) do
    root = review["project_dir"]
    intents = review["intents"]

    [
      "# Proposal review",
      "",
      "- **Proposal:** `#{proposal["id"]}`",
      "- **Workflow:** `#{workflow["id"]}`",
      if(root, do: "- **Project:** `#{root}`"),
      "- **Status:** #{workflow["status"]} (#{workflow["mode"]} mode)",
      "- **Intents:** #{length(intents)}",
      if(present?(proposal["justification"]),
        do: ["", "## Justification", "", proposal["justification"]]
      ),
      if(list_present?(proposal["claims"]),
        do: ["", "## Claims", "", Enum.map(proposal["claims"], &"- #{&1}")]
      ),
      if(review["validation_error"],
        do: validation_failed(review["validation_error"], intents, root)
      ),
      "",
      "## Intents",
      Enum.map(intents, &intent_section(&1, root)),
      if(list_present?(proposal["dependencies"]),
        do: ["", "## Dependencies", "", Enum.map(proposal["dependencies"], &"- #{&1}")]
      ),
      if(review["raw_output"],
        do: ["", "## Raw model output", "", artifact(review["raw_output"], "")]
      ),
      next_step(workflow, proposal)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## Intents

  defp intent_section(intent, root) do
    ["", "### #{intent["index"]}. #{heading(intent, root)}", "", body(intent, root)]
  end

  defp heading(%{"type" => type} = intent, _root) when type in ["EditFile", "WriteFile", "ReadFile", "DeleteFile"],
    do: "#{type} #{code(path(intent))}"

  defp heading(%{"type" => type}, _root), do: type

  # Inside the project the document gives a relative path; elsewhere, the
  # path as recorded.
  defp path(intent), do: intent["relative_path"] || intent["path"]

  defp body(%{"type" => "EditFile"} = edit, _root) do
    language = language(edit["path"])

    [
      if(edit["replace_all"], do: ["_Replaces every occurrence._", ""]),
      "**Replace**",
      "",
      artifact(edit["old_string"], language),
      "",
      "**With**",
      "",
      artifact(edit["new_string"], language)
    ]
  end

  defp body(%{"type" => "WriteFile", "path" => path, "artifact" => contents}, _root),
    do: artifact(contents, language(path))

  defp body(%{"type" => "ReadFile"}, _root), do: "Reads the file."
  defp body(%{"type" => "DeleteFile"}, _root), do: "Deletes the file."

  defp body(%{"type" => "RunCommand", "cmd" => cmd} = intent, _root),
    do: fenced(Enum.join([cmd | intent["args"] || []], " "), "sh")

  defp body(%{"type" => "Grep", "pattern" => pattern} = intent, root),
    do:
      "Searches for #{code(pattern)} in " <>
        Enum.map_join(intent["paths"] || [], ", ", &code(rel(&1, root)))

  defp body(%{"type" => "Glob", "pattern" => pattern} = intent, root),
    do: "Lists files matching #{code(pattern)} under #{code(rel(intent["base_dir"], root))}"

  defp body(%{"type" => "Claim"} = claim, _root) do
    [
      quote_block(claim["statement"]),
      "",
      if(claim["evidence"],
        do: "**Evidence:** #{evidence(claim["evidence"])}",
        else: "**Evidence:** none"
      ),
      if(claim["expected"] != nil, do: ["", "**Expected:** #{inspect(claim["expected"])}"])
    ]
  end

  defp body(%{"type" => "Report"} = intent, _root),
    do: if(present?(intent["summary"]), do: quote_block(intent["summary"]), else: "_No summary._")

  defp body(_intent, _root), do: []

  defp evidence(%{} = evidence) do
    source =
      case evidence["source_intent_index"] do
        nil -> "intent #{code(to_string(evidence["source_intent_id"]))}"
        index -> "intent #{index}"
      end

    value = inspect(evidence["value"])

    case evidence["condition"] do
      "exit_code_equals" -> "the exit code of #{source} equals #{value}"
      "match_count_equals" -> "the match count of #{source} equals #{value}"
      "match_count_greater_than" -> "the match count of #{source} is greater than #{value}"
      other -> "#{code(inspect(other))} #{value} on #{source}"
    end
  end

  ## Artifacts

  defp artifact(%{"status" => "ok", "total_lines" => 0} = excerpt, _language),
    do: "_Empty (#{code(Render.short(excerpt["id"]))})._"

  defp artifact(%{"status" => "ok"} = excerpt, language) do
    [
      fenced(excerpt["text"], language),
      if(excerpt["truncated"],
        do: [
          "",
          "_… showing #{excerpt["shown_lines"]} of #{excerpt["total_lines"]} lines" <>
            if(excerpt["lines_shortened"], do: ", long lines shortened", else: "") <>
            " · full: #{full(excerpt)}_"
        ]
      )
    ]
  end

  defp artifact(%{"status" => "binary"} = excerpt, _language),
    do: "_Binary content (#{excerpt["total_bytes"]} bytes) · #{full(excerpt)}_"

  defp artifact(%{"status" => "missing", "id" => id}, _language),
    do: "_Artifact not found: #{code(id)}_"

  defp artifact(%{"status" => "omitted"} = excerpt, _language),
    do: "_Not shown: this review's line limit was reached · #{full(excerpt)}_"

  defp full(%{"id" => id}), do: code("current artifact #{Render.short(id)}")

  ## Validation and next step

  defp validation_failed(error, intents, root) do
    at =
      case error["intent_index"] do
        nil -> "intent #{code(to_string(error["intent_id"]))}"
        index -> "intent #{index} (#{heading(Enum.at(intents, index - 1), root)})"
      end

    [
      "",
      "## ✗ Validation failed",
      "",
      "- **At:** #{at}",
      "- **Reason:** #{error["reason"]}",
      if(error["details"] not in [nil, %{}],
        do: "- **Details:** #{code(JSON.encode!(error["details"]))}"
      )
    ]
  end

  defp next_step(%{"status" => "waiting_for_approval", "mode" => "apply"}, proposal) do
    [
      "",
      "---",
      "",
      "Waiting for approval. Nothing has been applied.",
      "",
      "Approve with: #{code("current approve #{Render.short(proposal["id"])} -m \"<message>\"")}",
      "",
      "Approving doesn't apply it; `current apply` does that afterwards."
    ]
  end

  defp next_step(%{"status" => "approved"}, proposal) do
    [
      "",
      "---",
      "",
      "Approved. Nothing has been applied yet.",
      "",
      "Apply with: #{code("current apply #{Render.short(proposal["id"])}")}"
    ]
  end

  defp next_step(_workflow, _proposal), do: []

  ## Markdown helpers

  # A fence longer than any run of backticks in the text, so content that
  # itself contains ``` can't close the block early.
  defp fenced(text, language) do
    longest =
      ~r/`+/
      |> Regex.scan(text)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", max(3, longest + 1))
    ["#{fence}#{language}", text, fence]
  end

  # Inline code that survives backticks in the text.
  defp code(text) do
    text = to_string(text)

    if String.contains?(text, "`"),
      do: "`` #{text} ``",
      else: "`#{text}`"
  end

  defp quote_block(text), do: text |> String.split("\n") |> Enum.map(&"> #{&1}")

  @languages %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".ts" => "typescript",
    ".tsx" => "tsx",
    ".js" => "javascript",
    ".jsx" => "jsx",
    ".py" => "python",
    ".rb" => "ruby",
    ".go" => "go",
    ".rs" => "rust",
    ".java" => "java",
    ".json" => "json",
    ".md" => "markdown",
    ".yml" => "yaml",
    ".yaml" => "yaml",
    ".toml" => "toml",
    ".sh" => "sh",
    ".css" => "css",
    ".html" => "html",
    ".sql" => "sql"
  }

  defp language(path) when is_binary(path),
    do: Map.get(@languages, path |> Path.extname() |> String.downcase(), "")

  defp language(_path), do: ""

  defp rel(path, root) when is_binary(path) and is_binary(root), do: Path.relative_to(path, root)
  defp rel(path, _root), do: to_string(path)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp list_present?(value), do: is_list(value) and value != []
end
