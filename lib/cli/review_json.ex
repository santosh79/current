defmodule Current.CLI.ReviewJSON do
  @moduledoc """
  The machine-readable form of `current review`: a versioned document,
  built field by field from Current.Inspector.review/2 rather than by
  serializing the runtime's structs, so it only changes on purpose.

  Schema `current.review/v1`:

      {
        "schema": "current.review/v1",
        "proposal": {"id", "workflow_id", "justification", "claims", "dependencies"},
        "workflow": {"id", "status", "mode"},
        "project_dir": string | null,
        "validation_error": {"intent_id", "intent_index", "reason", "details"} | null,
        "intents": [
          {"index", "id", "type", ...type-specific fields,
           "artifact": artifact | absent}
        ],
        "raw_output": artifact | null,
        "limits": {"max_lines_per_artifact", "max_total_lines"}
      }

  An artifact is `{"id", "status", "text", "truncated", "lines_shortened",
  "total_bytes", "total_lines", "shown_lines"}`, with `status` one of "ok", "binary",
  "missing" or "omitted" (see Current.Excerpt). `text` is null unless
  status is "ok".

  Key order is not significant. Intent indexes are 1-based, matching the Markdown form. Paths are
  given as recorded (absolute) and, when inside the project, relative to
  it as `relative_path`. Ids are always full.
  """

  alias Current.{Excerpt, Intent}
  alias Current.Error.ValidationError

  @schema "current.review/v1"

  @spec encode(Current.Inspector.review_view()) :: String.t()
  def encode(review) do
    review
    |> to_map()
    |> JSON.encode!()
    # Pretty-printed for people; tools don't mind.
    |> :json.decode()
    |> :json.format()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec to_map(Current.Inspector.review_view()) :: map()
  def to_map(%{proposal: proposal} = review) do
    intents = proposal.intents

    %{
      "schema" => @schema,
      "proposal" => %{
        "id" => proposal.id,
        "workflow_id" => proposal.workflow_id,
        "justification" => proposal.justification,
        "claims" => proposal.claims || [],
        "dependencies" => proposal.dependencies || []
      },
      "workflow" => %{
        "id" => review.workflow_id,
        "status" => Atom.to_string(review.status),
        "mode" => Atom.to_string(review.mode)
      },
      "project_dir" => review.project_dir,
      "validation_error" => validation_error(review.validation_error, intents),
      "intents" =>
        intents
        |> Enum.with_index(1)
        |> Enum.map(fn {intent, n} -> intent(intent, n, review) end),
      "raw_output" => review.raw_output && artifact(review.raw_output),
      "limits" => %{
        "max_lines_per_artifact" => review.limits.max_lines,
        "max_total_lines" => review.limits.max_total_lines
      }
    }
  end

  defp intent(%{__struct__: mod, id: id} = intent, n, review) do
    Map.merge(
      %{"index" => n, "id" => id, "type" => mod |> Module.split() |> List.last()},
      fields(intent, review)
    )
  end

  defp fields(%Intent.FilePatch{path: path, diff_artifact_id: id}, review),
    do: Map.merge(path(path, review), %{"artifact" => artifact_for(id, review)})

  defp fields(%Intent.WriteFile{path: path, contents_artifact_id: id}, review),
    do: Map.merge(path(path, review), %{"artifact" => artifact_for(id, review)})

  defp fields(%Intent.ReadFile{path: path}, review), do: path(path, review)
  defp fields(%Intent.DeleteFile{path: path}, review), do: path(path, review)

  defp fields(%Intent.RunCommand{cmd: cmd, args: args}, _review),
    do: %{"cmd" => cmd, "args" => args || []}

  defp fields(%Intent.Grep{pattern: pattern, paths: paths}, _review),
    do: %{"pattern" => pattern, "paths" => paths || []}

  defp fields(%Intent.Glob{pattern: pattern, base_dir: base_dir}, _review),
    do: %{"pattern" => pattern, "base_dir" => base_dir}

  defp fields(%Intent.Claim{} = claim, review) do
    %{
      "statement" => claim.statement,
      "expected" => claim.expected,
      "evidence" => claim.evidence && evidence(claim.evidence, review.proposal.intents)
    }
  end

  defp fields(%Intent.Report{summary: summary}, _review), do: %{"summary" => summary}
  defp fields(_intent, _review), do: %{}

  defp path(path, %{project_dir: root}) do
    relative =
      if is_binary(root) and is_binary(path) and inside?(path, root),
        do: Path.relative_to(path, root)

    %{"path" => path, "relative_path" => relative}
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp evidence(%{} = evidence, intents) do
    source_id = Map.get(evidence, :source_intent_id)

    %{
      "source_intent_id" => source_id,
      "source_intent_index" => index_of(intents, source_id),
      "condition" => evidence |> Map.get(:condition) |> jsonable(),
      "value" => evidence |> Map.get(:value) |> jsonable()
    }
  end

  defp validation_error(nil, _intents), do: nil

  defp validation_error(%ValidationError{} = error, intents) do
    %{
      "intent_id" => error.intent_id,
      "intent_index" => index_of(intents, error.intent_id),
      "reason" => error.reason,
      "details" => jsonable(error.details || %{})
    }
  end

  defp artifact_for(id, review),
    do: review.artifacts |> Map.get(id, %Excerpt{id: id, status: :missing}) |> artifact()

  defp artifact(%Excerpt{} = excerpt) do
    %{
      "id" => excerpt.id,
      "status" => Atom.to_string(excerpt.status),
      "text" => excerpt.text,
      "truncated" => excerpt.truncated,
      "lines_shortened" => excerpt.lines_shortened,
      "total_bytes" => excerpt.total_bytes,
      "total_lines" => excerpt.total_lines,
      "shown_lines" => excerpt.shown_lines
    }
  end

  defp index_of(intents, id) do
    case Enum.find_index(intents, &(&1.id == id)) do
      nil -> nil
      index -> index + 1
    end
  end

  # Free-form values (validation details, evidence values) as JSON:
  # anything JSON has no form for is given as its inspect/1 string.
  defp jsonable(value) when is_nil(value) or is_boolean(value), do: value
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value) when is_number(value), do: value

  defp jsonable(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  defp jsonable(value) when is_list(value) do
    if List.improper?(value), do: inspect(value), else: Enum.map(value, &jsonable/1)
  end

  defp jsonable(%_{} = struct), do: inspect(struct)

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {key(k), jsonable(v)} end)

  defp jsonable(value), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
