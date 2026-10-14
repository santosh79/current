defmodule Current.Observer do
  @moduledoc """
  Makes the observations a model asks for while it is still working out
  its proposal, and renders what they found as text for the next prompt.

  A model is given a project's layout, not its contents (see
  Current.ProjectContext). To see contents it replies with observations
  instead of a proposal (see Current.Observation), each wrapping a
  `read_file`, `glob` or `grep` intent; those come here.

  Nothing is read on the model's say-so alone. Every intent goes through
  the same gates as an intent in an approved proposal, plus the read
  policy:

    1. its paths are made absolute against the project directory
       (Current.IntentPaths.absolutize_intents/2);
    2. they must be inside it, with symlinks followed
       (Current.IntentPaths.resolved_violation/2);
    3. they must be something a model may be shown (Current.ReadPolicy);
    4. the read itself is done by Current.EffectApplicator, which checks
       containment again immediately before touching the filesystem.

  An intent that fails a gate, or whose read fails, is not an error for
  the workflow. The model is told what went wrong in place of a result --
  a mistyped path is something it can correct on its next turn.

  What a model can be shown is bounded: a file over 200 KB is not shown,
  long result lists are cut, and the caller passes a byte budget that
  all results together must fit in.
  """

  alias Current.{
    BlobStore,
    EffectApplicator,
    EffectResult,
    Intent,
    IntentPaths,
    Observation,
    ReadPolicy
  }

  @read_only [Intent.ReadFile, Intent.Glob, Intent.Grep]

  # More than this in one reply is a model looping, not exploring.
  @max_intents_per_round 20

  # A file larger than this isn't shown at all: half a file is worse
  # than none for writing a patch against it.
  @max_read_bytes 200_000

  # grep reads each file it searches; keep it away from huge ones.
  @max_grep_file_bytes 2_000_000

  # Paths (glob) or lines (grep) shown per result, and how much of a
  # matching line.
  @max_matches 200
  @max_line_chars 300
  @max_heading_chars 300
  @max_error_chars 500

  @doc """
  Makes each of `observations` against `project_dir`: runs its intent
  and settles it as `:shown` or `:refused` (see Current.Observation).

  Returns, in order, each settled observation paired with the text that
  tells the model about it -- a line saying what was asked, then the
  result or the reason there is none -- and what is left of `budget`
  (bytes of result text). Paths in the text are relative to the project.

  The text is the only place contents appear. The observation itself
  holds the id of the artifact that was shown, nothing more.
  """
  @spec observe([Observation.t()], Path.t(), non_neg_integer()) ::
          {[{Observation.t(), String.t()}], non_neg_integer()}
  def observe(observations, project_dir, budget)
      when is_list(observations) and is_binary(project_dir) and is_integer(budget) and
             budget >= 0 do
    root = Path.expand(project_dir)

    observations
    |> Enum.with_index()
    |> Enum.map_reduce(budget, fn {%Observation{intent: intent} = observation, index}, budget ->
      heading = intent |> heading() |> clip(@max_heading_chars)

      case outcome(intent, index, root) do
        {:ok, text, artifact_id} ->
          rendered = heading <> "\n" <> text

          if byte_size(rendered) <= budget do
            {{Observation.shown(observation, artifact_id), rendered},
             budget - byte_size(rendered)}
          else
            refuse(
              observation,
              heading,
              "not shown -- this result is #{byte_size(rendered)} bytes and only #{budget} " <>
                "bytes of context are left for this task",
              budget
            )
          end

        {:error, reason} ->
          refuse(observation, heading, reason, budget)
      end
    end)
  end

  defp refuse(observation, heading, reason, budget) do
    reason = clip(reason, @max_error_chars)
    rendered = heading <> "\nerror: " <> reason

    {{Observation.refused(observation, reason), rendered}, max(budget - byte_size(rendered), 0)}
  end

  defp outcome(_intent, index, _root) when index >= @max_intents_per_round do
    {:error, "not run -- at most #{@max_intents_per_round} requests are run per reply"}
  end

  defp outcome(intent, _index, root), do: run(intent, root)

  defp clip(text, max_chars) do
    if String.length(text) > max_chars,
      do: String.slice(text, 0, max_chars) <> " ...",
      else: text
  end

  ## --- Gates, then the read ------------------------------------------------

  defp run(%mod{} = intent, root) when mod in @read_only do
    [intent] = IntentPaths.absolutize_intents([intent], root)

    with :ok <- contained(intent, root),
         :ok <- permitted(intent, root),
         :ok <- small_enough(intent, root),
         {:ok, result} <- EffectApplicator.apply(intent, [], root) do
      render(intent, result, root)
    end
  catch
    # Whatever a model-chosen path or pattern manages to break, it breaks
    # this one observation, never the builder.
    kind, reason -> {:error, "failed: " <> Exception.format_banner(kind, reason)}
  end

  defp run(_intent, _root), do: {:error, "only read_file, glob and grep can be observed"}

  defp contained(intent, root) do
    case IntentPaths.resolved_violation(intent, root) do
      nil -> :ok
      {field, _path, problem} -> {:error, "#{field} #{describe(problem)}"}
    end
  end

  defp describe(:not_absolute), do: "is not a usable path"
  defp describe(:outside_project_dir), do: "is outside the project directory"
  defp describe(:parent_segment), do: "must not contain '..'"
  defp describe(:too_many_links), do: "has too many levels of symbolic links"

  defp permitted(intent, root) do
    intent
    |> IntentPaths.path_fields()
    |> Enum.find_value(:ok, fn {_field, path} ->
      case is_binary(path) && ReadPolicy.violation(path, root) do
        {:excluded, name} ->
          {:error,
           "#{relative(path, root)} is not available: #{name} is excluded " <>
             "(dependencies, build output and secrets are never shown)"}

        _ ->
          nil
      end
    end)
  end

  defp small_enough(%Intent.ReadFile{path: path}, root),
    do: within_size(path, @max_read_bytes, root)

  defp small_enough(%Intent.Grep{paths: paths}, root) do
    Enum.find_value(paths, :ok, fn path ->
      case within_size(path, @max_grep_file_bytes, root) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp small_enough(%Intent.Glob{}, _root), do: :ok

  # A path that can't be stat'ed is left for the read to report.
  defp within_size(path, limit, root) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > limit ->
        {:error, "#{relative(path, root)} is #{size} bytes; the limit is #{limit}"}

      _ ->
        :ok
    end
  end

  ## --- Results as prompt text ----------------------------------------------

  defp render(%Intent.ReadFile{path: path}, %EffectResult.ReadFile{} = result, root) do
    {:ok, contents} = BlobStore.read(result.contents_artifact_id)

    if String.valid?(contents) do
      # The closing tag goes on its own line without adding a line the
      # file doesn't have: a patch is written against exactly these lines.
      newline = if contents == "" or String.ends_with?(contents, "\n"), do: "", else: "\n"

      {:ok, "<file path=\"#{relative(path, root)}\">\n#{contents}#{newline}</file>",
       result.contents_artifact_id}
    else
      {:error, "#{relative(path, root)} is a binary file"}
    end
  end

  # Glob matches come from Path.wildcard/1, which knows nothing of the
  # read policy: a pattern like "**/*" reaches into node_modules, and
  # "**/.env*" asks for exactly what must not be listed.
  defp render(%Intent.Glob{}, %EffectResult.Glob{} = result, root) do
    paths =
      result.matches_artifact_id
      |> stored_term()
      |> Enum.filter(&(ReadPolicy.violation(&1, root) == nil))
      |> Enum.map(&relative(&1, root))

    shown(listing(paths, "match", "matches", & &1))
  end

  defp render(%Intent.Grep{}, %EffectResult.Grep{} = result, root) do
    matches =
      result.matches_artifact_id
      |> stored_term()
      |> Enum.filter(&String.valid?(&1.text))

    shown(
      listing(matches, "matching line", "matching lines", fn match ->
        "#{relative(match.path, root)}:#{match.line}: #{shorten(match.text)}"
      end)
    )
  end

  # A listing is not what EffectApplicator stored (that is every match,
  # unfiltered, as an Erlang term); it is what is left after the read
  # policy and the caps. That is what the model sees, so that is what is
  # kept to be found again.
  defp shown(text) do
    {:ok, artifact_id} = BlobStore.put(text)
    {:ok, text, artifact_id}
  end

  defp listing(items, singular, plural, line) do
    count = length(items)
    noun = if count == 1, do: singular, else: plural
    shown = items |> Enum.take(@max_matches) |> Enum.map(line)

    more =
      if count > @max_matches,
        do: ["... #{count - @max_matches} more not shown; narrow the request"],
        else: []

    Enum.join(["#{count} #{noun}" | shown] ++ more, "\n")
  end

  defp shorten(text), do: clip(text, @max_line_chars)

  # An artifact EffectApplicator just wrote itself, not model input.
  defp stored_term(artifact_id) do
    {:ok, encoded} = BlobStore.read(artifact_id)
    :erlang.binary_to_term(encoded)
  end

  defp relative(path, root), do: Path.relative_to(path, root)

  ## --- What was asked, as the model wrote it ---------------------------------

  defp heading(%Intent.ReadFile{path: path}), do: "read_file #{path}"

  defp heading(%Intent.Glob{pattern: pattern, base_dir: base_dir}),
    do: "glob #{pattern} in #{base_dir}"

  defp heading(%Intent.Grep{pattern: pattern, paths: paths}),
    do: "grep #{inspect(pattern)} in #{Enum.join(paths, ", ")}"

  defp heading(%mod{}), do: inspect(mod)
end
