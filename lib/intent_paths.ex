defmodule Current.IntentPaths do
  @moduledoc """
  The one place that knows which intent fields are filesystem paths, and
  how they relate to a workflow's project directory.

  `absolutize/2` is mechanical: every path field is expanded against the
  project directory, so a relative path from the model means "relative to
  the project", never "relative to wherever this node happens to be
  running". It does not judge the result -- a path that expands to
  somewhere outside the project comes out absolute and outside, and
  `violation/2` (called by IntentValidator) is what rejects it.

  There are two containment checks:

    * `violation/2` is lexical: `..` and `.` segments are collapsed but
      symlinks are not followed. IntentValidator uses it, so an obvious
      escape is rejected before a human is ever asked to approve it.
    * `resolved_violation/2` additionally follows every symlink that
      exists on disk right now (see `realpath/1`). EffectApplicator calls
      it immediately before touching the filesystem, because only at
      apply time does "what does this path actually point at" have a
      meaningful answer -- approval can come long after validation.
  """

  alias Current.{Intent, Proposal}

  @single_path_intents [Intent.ReadFile, Intent.WriteFile, Intent.DeleteFile, Intent.EditFile]

  @spec absolutize(Proposal.t(), Path.t()) :: Proposal.t()
  def absolutize(%Proposal{intents: intents} = proposal, project_dir) do
    %{proposal | intents: absolutize_intents(intents, project_dir)}
  end

  @doc "`absolutize/2` for intents that aren't part of a proposal."
  @spec absolutize_intents([Intent.t()], Path.t()) :: [Intent.t()]
  def absolutize_intents(intents, project_dir) when is_list(intents) do
    root = Path.expand(project_dir)
    Enum.map(intents, &absolutize_intent(&1, root))
  end

  @doc """
  Returns nil if every path in `intent` is absolute and inside
  `project_dir`, otherwise `{field, offending_value, problem}`.
  """
  @spec violation(Intent.t(), Path.t()) ::
          nil | {atom(), term(), :not_absolute | :outside_project_dir | :parent_segment}
  def violation(%Intent.Glob{pattern: pattern} = intent, project_dir) do
    if is_binary(pattern) and parent_segment?(pattern) do
      {:pattern, pattern, :parent_segment}
    else
      first_violation(path_fields(intent), project_dir)
    end
  end

  def violation(intent, project_dir), do: first_violation(path_fields(intent), project_dir)

  @doc """
  Like `violation/2`, then additionally requires every path to still be
  inside `project_dir` once all existing symlinks -- in the path and in
  `project_dir` itself -- are followed.
  """
  @spec resolved_violation(Intent.t(), Path.t()) ::
          nil
          | {atom(), term(),
             :not_absolute | :outside_project_dir | :parent_segment | :too_many_links}
  def resolved_violation(intent, project_dir) do
    violation(intent, project_dir) ||
      Enum.find_value(path_fields(intent), fn {field, path} ->
        case resolved_within(path, project_dir) do
          :ok -> nil
          {:error, problem} -> {field, path, problem}
        end
      end)
  end

  @doc """
  `:ok` if `path`, with every existing symlink followed, is inside
  `project_dir`, likewise resolved.
  """
  @spec resolved_within(Path.t(), Path.t()) ::
          :ok | {:error, :not_absolute | :outside_project_dir | :too_many_links}
  def resolved_within(path, project_dir) when is_binary(path) do
    with :absolute <- Path.type(path),
         {:ok, real_root} <- realpath(Path.expand(project_dir)),
         {:ok, real_path} <- realpath(path) do
      if within?(real_path, real_root), do: :ok, else: {:error, :outside_project_dir}
    else
      :relative -> {:error, :not_absolute}
      :volumerelative -> {:error, :not_absolute}
      {:error, _} = error -> error
    end
  end

  def resolved_within(_path, _project_dir), do: {:error, :not_absolute}

  @max_symlinks 40

  @doc """
  Resolves an absolute path the way the OS would: component by
  component, following each symlink that exists (relative targets are
  relative to the link's own directory) and applying `..` to the
  already-resolved prefix, not lexically. Components that don't exist
  yet (a file about to be written) are kept as-is.

  Gives up with `{:error, :too_many_links}` after #{@max_symlinks}
  links, so a symlink loop can't hang the caller.
  """
  @spec realpath(Path.t()) :: {:ok, Path.t()} | {:error, :too_many_links}
  def realpath(path) do
    [root | parts] = Path.split(path)
    walk(parts, root, @max_symlinks)
  end

  defp walk([], resolved, _budget), do: {:ok, resolved}
  defp walk(["." | rest], resolved, budget), do: walk(rest, resolved, budget)
  defp walk([".." | rest], resolved, budget), do: walk(rest, Path.dirname(resolved), budget)

  defp walk([part | rest], resolved, budget) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, _target} when budget == 0 ->
        {:error, :too_many_links}

      {:ok, target} ->
        # An absolute target restarts from the filesystem root; a relative
        # one continues from the directory containing the link. Either way
        # the target's own components are walked too, so links in the
        # target are followed and its `..`s apply to real directories.
        case {Path.type(target), Path.split(target)} do
          {:absolute, [fs_root | target_parts]} ->
            walk(target_parts ++ rest, fs_root, budget - 1)

          {_relative, target_parts} ->
            walk(target_parts ++ rest, resolved, budget - 1)
        end

      {:error, _not_a_link_or_missing} ->
        walk(rest, candidate, budget)
    end
  end

  @spec parent_segment?(Path.t()) :: boolean()
  def parent_segment?(path), do: ".." in Path.split(path)

  @doc "True if `path` is `root` itself or somewhere beneath it."
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(path, root) do
    root_parts = root |> Path.expand() |> Path.split()
    path_parts = path |> Path.expand() |> Path.split()
    Enum.take(path_parts, length(root_parts)) == root_parts
  end

  ## --- Internals -----------------------------------------------------------

  defp absolutize_intent(%Intent.Grep{paths: paths} = intent, root) when is_list(paths),
    do: %{intent | paths: Enum.map(paths, &expand(&1, root))}

  defp absolutize_intent(%Intent.Glob{base_dir: base_dir} = intent, root),
    do: %{intent | base_dir: expand(base_dir, root)}

  defp absolutize_intent(%mod{path: path} = intent, root) when mod in @single_path_intents,
    do: %{intent | path: expand(path, root)}

  defp absolutize_intent(intent, _root), do: intent

  # Empty strings and non-strings are left alone so IntentValidator's own
  # shape checks still see them; Path.expand("", root) would silently
  # turn an empty path into the project root.
  defp expand(path, root) when is_binary(path) and path != "", do: Path.expand(path, root)
  defp expand(path, _root), do: path

  @doc "Every `{field, value}` pair in `intent` that names a filesystem path."
  @spec path_fields(Intent.t()) :: [{atom(), term()}]
  def path_fields(%Intent.Grep{paths: paths}) when is_list(paths),
    do: Enum.map(paths, &{:paths, &1})

  def path_fields(%Intent.Glob{base_dir: base_dir}), do: [{:base_dir, base_dir}]
  def path_fields(%mod{path: path}) when mod in @single_path_intents, do: [{:path, path}]
  def path_fields(_intent), do: []

  defp first_violation(fields, project_dir) do
    Enum.find_value(fields, fn
      {field, path} when is_binary(path) and path != "" ->
        cond do
          Path.type(path) != :absolute -> {field, path, :not_absolute}
          not within?(path, project_dir) -> {field, path, :outside_project_dir}
          true -> nil
        end

      # Wrong shape (empty, non-string): the per-intent checks own that.
      _ ->
        nil
    end)
  end
end
