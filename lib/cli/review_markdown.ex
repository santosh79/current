defmodule Current.CLI.ReviewMarkdown do
  @moduledoc """
  Renders Current.Inspector.review/2 as Markdown, laid out like a pull
  request: what the proposal is and why, then each intent in order with
  its artifact inline -- a diff for a FilePatch, the new contents for a
  WriteFile.

  Pure, like Current.CLI.Render: data in, string out.
  """

  alias Current.{Excerpt, Intent}
  alias Current.CLI.Render
  alias Current.Error.ValidationError

  @spec render(Current.Inspector.review_view()) :: String.t()
  def render(%{proposal: proposal} = review) do
    root = review.project_dir
    intents = proposal.intents

    [
      "# Proposal review",
      "",
      "- **Proposal:** `#{proposal.id}`",
      "- **Workflow:** `#{review.workflow_id}`",
      if(root, do: "- **Project:** `#{root}`"),
      "- **Status:** #{review.status} (#{review.mode} mode)",
      "- **Intents:** #{length(intents)}",
      if(present?(proposal.justification),
        do: ["", "## Justification", "", proposal.justification]
      ),
      if(list_present?(proposal.claims),
        do: ["", "## Claims", "", Enum.map(proposal.claims, &"- #{&1}")]
      ),
      if(review.validation_error, do: validation_failed(review.validation_error, intents, root)),
      "",
      "## Intents",
      intents
      |> Enum.with_index(1)
      |> Enum.map(fn {intent, n} -> intent_section(intent, n, review, root) end),
      if(list_present?(proposal.dependencies),
        do: ["", "## Dependencies", "", Enum.map(proposal.dependencies, &"- #{&1}")]
      ),
      if(review.raw_output,
        do: ["", "## Raw model output", "", artifact(review.raw_output, "")]
      ),
      next_step(review)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## Intents

  defp intent_section(intent, n, review, root) do
    ["", "### #{n}. #{heading(intent, root)}", "", body(intent, review, root)]
  end

  defp heading(%Intent.FilePatch{path: path}, root), do: "FilePatch #{code(rel(path, root))}"
  defp heading(%Intent.WriteFile{path: path}, root), do: "WriteFile #{code(rel(path, root))}"
  defp heading(%Intent.ReadFile{path: path}, root), do: "ReadFile #{code(rel(path, root))}"
  defp heading(%Intent.DeleteFile{path: path}, root), do: "DeleteFile #{code(rel(path, root))}"
  defp heading(%{__struct__: mod}, _root), do: mod |> Module.split() |> List.last()

  defp body(%Intent.FilePatch{diff_artifact_id: id}, review, _root),
    do: artifact(Map.get(review.artifacts, id, missing(id)), "diff")

  defp body(%Intent.WriteFile{path: path, contents_artifact_id: id}, review, _root),
    do: artifact(Map.get(review.artifacts, id, missing(id)), language(path))

  defp body(%Intent.ReadFile{}, _review, _root), do: "Reads the file."
  defp body(%Intent.DeleteFile{}, _review, _root), do: "Deletes the file."

  defp body(%Intent.RunCommand{cmd: cmd, args: args}, _review, _root),
    do: fenced(Enum.join([cmd | args || []], " "), "sh")

  defp body(%Intent.Grep{pattern: pattern, paths: paths}, _review, root),
    do:
      "Searches for #{code(pattern)} in " <>
        Enum.map_join(paths || [], ", ", &code(rel(&1, root)))

  defp body(%Intent.Glob{pattern: pattern, base_dir: base_dir}, _review, root),
    do: "Lists files matching #{code(pattern)} under #{code(rel(base_dir, root))}"

  defp body(%Intent.Claim{} = claim, review, _root) do
    [
      quote_block(claim.statement),
      "",
      if(claim.evidence,
        do: "**Evidence:** #{evidence(claim.evidence, review.proposal.intents)}",
        else: "**Evidence:** none"
      ),
      if(claim.expected != nil, do: ["", "**Expected:** #{inspect(claim.expected)}"])
    ]
  end

  defp body(%Intent.Report{summary: summary}, _review, _root),
    do: if(present?(summary), do: quote_block(summary), else: "_No summary._")

  defp body(_intent, _review, _root), do: []

  defp evidence(%{} = evidence, intents) do
    source =
      case Enum.find_index(intents, &(&1.id == Map.get(evidence, :source_intent_id))) do
        nil -> "intent #{code(to_string(Map.get(evidence, :source_intent_id)))}"
        index -> "intent #{index + 1}"
      end

    value = inspect(Map.get(evidence, :value))

    case Map.get(evidence, :condition) do
      :exit_code_equals -> "the exit code of #{source} equals #{value}"
      :match_count_equals -> "the match count of #{source} equals #{value}"
      :match_count_greater_than -> "the match count of #{source} is greater than #{value}"
      other -> "#{code(inspect(other))} #{value} on #{source}"
    end
  end

  ## Artifacts

  defp missing(id), do: %Excerpt{id: id, status: :missing}

  defp artifact(%Excerpt{status: :ok, total_lines: 0} = excerpt, _language),
    do: "_Empty (#{code(Render.short(excerpt.id))})._"

  defp artifact(%Excerpt{status: :ok} = excerpt, language) do
    [
      fenced(excerpt.text, language),
      if(excerpt.truncated,
        do: [
          "",
          "_… showing #{excerpt.shown_lines} of #{excerpt.total_lines} lines" <>
            if(excerpt.lines_shortened, do: ", long lines shortened", else: "") <>
            " · full: #{full(excerpt)}_"
        ]
      )
    ]
  end

  defp artifact(%Excerpt{status: :binary} = excerpt, _language),
    do: "_Binary content (#{excerpt.total_bytes} bytes) · #{full(excerpt)}_"

  defp artifact(%Excerpt{status: :missing, id: id}, _language),
    do: "_Artifact not found: #{code(id)}_"

  defp artifact(%Excerpt{status: :omitted} = excerpt, _language),
    do: "_Not shown: this review's line limit was reached · #{full(excerpt)}_"

  defp full(%Excerpt{id: id}), do: code("current artifact #{Render.short(id)}")

  ## Validation and next step

  defp validation_failed(%ValidationError{} = error, intents, root) do
    at =
      case Enum.find_index(intents, &(&1.id == error.intent_id)) do
        nil -> "intent #{code(to_string(error.intent_id))}"
        index -> "intent #{index + 1} (#{heading(Enum.at(intents, index), root)})"
      end

    [
      "",
      "## ✗ Validation failed",
      "",
      "- **At:** #{at}",
      "- **Reason:** #{error.reason}",
      if(error.details not in [nil, %{}],
        do: "- **Details:** #{code(inspect(error.details))}"
      )
    ]
  end

  defp next_step(%{status: :waiting_for_approval, mode: :apply, proposal: proposal}) do
    [
      "",
      "---",
      "",
      "Waiting for approval. Nothing has been applied.",
      "",
      "Approve with: #{code("current approve #{Render.short(proposal.id)} -m \"<message>\"")}",
      "",
      "Approving doesn't apply it; `current apply` does that afterwards."
    ]
  end

  defp next_step(%{status: :approved, proposal: proposal}) do
    [
      "",
      "---",
      "",
      "Approved. Nothing has been applied yet.",
      "",
      "Apply with: #{code("current apply #{Render.short(proposal.id)}")}"
    ]
  end

  defp next_step(_review), do: []

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
