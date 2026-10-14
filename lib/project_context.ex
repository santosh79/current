defmodule Current.ProjectContext do
  @moduledoc """
  The layout of a project -- which files it has and how big they are --
  for inclusion in an agent request. No file contents are read: a model
  is given the layout and asks for the contents it needs (see
  Current.Observer).

  Only what is physically inside the project is listed, and only what
  Current.ReadPolicy lets a model see. The walk uses `File.lstat/1`, so
  it sees symlinks as symlinks:

    * a symlinked directory is never descended into -- if its target is
      inside the project it is already listed under its real path, and if
      it is outside it must not be read (this also makes symlink loops
      impossible to follow);
    * a symlinked file is listed only if it resolves inside the project
      (see Current.IntentPaths.resolved_within/2) to something the read
      policy allows;
    * anything that isn't a regular file or directory (FIFOs, sockets,
      devices) is skipped.
  """

  alias Current.{IntentPaths, ReadPolicy}

  # A layout longer than this is cut; the model is told how many files
  # were left out and can still find them with glob.
  @max_entries 2_000

  @type entry :: %{path: Path.t(), bytes: non_neg_integer()}

  @type t :: %{root: Path.t(), files: [entry()], omitted: non_neg_integer()}

  @doc """
  Lists the project's files by project-relative path, directory by directory, with their
  sizes. At most #{@max_entries} are returned; `omitted` counts the rest.
  """
  @spec layout(Path.t()) :: {:ok, t()} | {:error, term()}
  def layout(root) do
    root = Path.expand(root)

    with :ok <- ensure_dir(root),
         {:ok, children} <- children(root),
         {:ok, paths} <- walk(children, [], root) do
      {listed, rest} = Enum.split(paths, @max_entries)
      {:ok, %{root: root, files: Enum.flat_map(listed, &entry(&1, root)), omitted: length(rest)}}
    end
  end

  # Depth-first walk over an explicit worklist of absolute paths, so the
  # whole walk is one tail-recursive loop. A directory's children are
  # sorted and pushed onto the front of the worklist, which lists the tree
  # directory by directory in name order. Returns {:ok, paths} or the
  # first error hit anywhere in the tree.
  defp walk([], acc, _root) do
    {:ok, :lists.reverse(acc)}
  end

  defp walk([path | rest], acc, root) do
    name = Path.basename(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case ReadPolicy.ignored_dir?(name) do
          true ->
            walk(rest, acc, root)

          _ ->
            case children(path) do
              {:ok, children} -> walk(children ++ rest, acc, root)
              {:error, reason} -> {:error, {:project_context_build_error, path, reason}}
            end
        end

      {:ok, %File.Stat{type: :regular}} ->
        case ReadPolicy.ignored_file?(name) do
          true ->
            walk(rest, acc, root)

          _ ->
            walk(rest, [path | acc], root)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        walk(rest, symlinked_file(path, name, root) ++ acc, root)

      {:ok, %File.Stat{}} ->
        walk(rest, acc, root)

      # Removed between File.ls/1 and here: nothing to snapshot.
      {:error, :enoent} ->
        walk(rest, acc, root)

      {:error, reason} ->
        {:error, {:project_context_build_error, path, reason}}
    end
  end

  # A directory's entries as full paths, in name order.
  defp children(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names |> Enum.sort() |> Enum.map(&Path.join(dir, &1))}
      {:error, reason} -> {:error, {:project_context_build_error, dir, reason}}
    end
  end

  # File.stat/1 follows a symlinked file to the file it names. A file
  # that vanished since the walk is simply not listed.
  defp entry(path, root) do
    case File.stat(path) do
      {:ok, %File.Stat{size: bytes}} -> [%{path: Path.relative_to(path, root), bytes: bytes}]
      {:error, _} -> []
    end
  end

  defp ensure_dir(root) do
    case File.dir?(root) do
      true -> :ok
      _ -> {:error, {:not_a_directory, root}}
    end
  end

  defp symlinked_file(path, name, root) do
    with false <- ReadPolicy.ignored_file?(name),
         :ok <- IntentPaths.resolved_within(path, root),
         nil <- ReadPolicy.violation(path, root),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
      [path]
    else
      # Excluded by the read policy (by its own name or its target's),
      # resolves outside the project, dangling, or not a file.
      _ -> []
    end
  end
end
