defmodule Current.ProjectContext do
  @moduledoc """
  Builds a snapshot of a project for inclusion in an agent request.

  Only what is physically inside the project is read. The walk uses
  `File.lstat/1`, so it sees symlinks as symlinks:

    * a symlinked directory is never descended into -- if its target is
      inside the project it is already listed under its real path, and if
      it is outside it must not be read (this also makes symlink loops
      impossible to follow);
    * a symlinked file is read only if it resolves inside the project
      (see Current.IntentPaths.resolved_within/2);
    * anything that isn't a regular file or directory (FIFOs, sockets,
      devices) is skipped -- reading a FIFO would block.
  """

  alias Current.IntentPaths

  @ignored_dirs MapSet.new([
                  ".git",
                  "node_modules",
                  "_build",
                  "deps"
                ])

  @ignored_files MapSet.new([
                   "package-lock.json"
                 ])

  @type t :: %{root: Path.t(), files: %{optional(Path.t()) => binary()}}

  @spec build(Path.t()) :: {:ok, t()} | {:error, term()}
  def build(root) do
    root = Path.expand(root)

    with :ok <- ensure_dir(root),
         {:ok, paths} <- collect_files(root, root),
         {:ok, files} <- read_files(paths, root) do
      {:ok, %{root: root, files: files}}
    end
  end

  defp ensure_dir(root) do
    if File.dir?(root), do: :ok, else: {:error, {:not_a_directory, root}}
  end

  # Returns {:ok, paths} or the first error hit anywhere in the tree, so a
  # failure in a nested directory surfaces to the caller instead of being
  # handed to Enum.flat_map/2 as if it were a list of paths.
  defp collect_files(dir, root) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case collect_entry(Path.join(dir, name), name, root) do
            {:ok, paths} -> {:cont, {:ok, [paths | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> Enum.concat()}
          error -> error
        end

      {:error, reason} ->
        {:error, {:project_context_build_error, dir, reason}}
    end
  end

  defp collect_entry(path, name, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@ignored_dirs, name), do: {:ok, []}, else: collect_files(path, root)

      {:ok, %File.Stat{type: :regular}} ->
        if MapSet.member?(@ignored_files, name), do: {:ok, []}, else: {:ok, [path]}

      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, symlinked_file(path, name, root)}

      {:ok, %File.Stat{}} ->
        {:ok, []}

      # Removed between File.ls/1 and here: nothing to snapshot.
      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:project_context_build_error, path, reason}}
    end
  end

  defp symlinked_file(path, name, root) do
    with false <- MapSet.member?(@ignored_files, name),
         :ok <- IntentPaths.resolved_within(path, root),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
      [path]
    else
      # Ignored, resolves outside the project, dangling, or not a file.
      _ -> []
    end
  end

  defp read_files(paths, root) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, contents} ->
          {:cont, {:ok, Map.put(acc, Path.relative_to(path, root), contents)}}

        {:error, reason} ->
          {:halt, {:error, {:project_context_build_error, path, reason}}}
      end
    end)
  end
end
