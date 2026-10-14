defmodule Current.ReadPolicy do
  @moduledoc """
  What a model may be shown of a project.

  Being inside the project directory (Current.IntentPaths) is necessary
  but not sufficient: dependencies, build output and tool state are
  never what a request is about, and secrets must never reach a prompt.
  This is the one place those rules live, so the project layout a model
  is given (Current.ProjectContext) and the files it may then ask to see
  (Current.Observer) cannot disagree.

  The rules are about names, and they are checked twice: on the path as
  written, and on the path with every symlink followed. A link called
  `notes.txt` that points at `.env` is refused like `.env` itself.
  """

  alias Current.IntentPaths

  # Dependencies, build output, caches and tool state: large, generated,
  # or both, and never what a request is about.
  @ignored_dirs MapSet.new([
                  # VCS
                  ".git",
                  ".hg",
                  ".svn",
                  # Elixir
                  "_build",
                  "deps",
                  "cover",
                  ".elixir_ls",
                  ".lexical",
                  # JS / TS
                  "node_modules",
                  ".next",
                  ".nuxt",
                  ".turbo",
                  ".parcel-cache",
                  "dist",
                  "coverage",
                  # Python
                  "__pycache__",
                  ".venv",
                  "venv",
                  ".pytest_cache",
                  ".mypy_cache",
                  # Rust / JVM
                  "target",
                  ".gradle",
                  # Editors / misc
                  ".idea",
                  ".cache",
                  "tmp",
                  "_data"
                ])

  # Lockfiles and dumps: text, but long and of no use to the model.
  @ignored_files MapSet.new([
                   "package-lock.json",
                   "yarn.lock",
                   "pnpm-lock.yaml",
                   "mix.lock",
                   "Cargo.lock",
                   "poetry.lock",
                   "Gemfile.lock",
                   "composer.lock",
                   ".DS_Store",
                   "erl_crash.dump"
                 ])

  @doc "Whether a directory with this name is never listed or entered."
  @spec ignored_dir?(String.t()) :: boolean()
  def ignored_dir?(path) do
    basename = Path.basename(path)
    MapSet.member?(@ignored_dirs, basename)
  end

  @doc """
  Whether a file with this name is never listed or shown. Secrets must
  never reach the prompt: .env, .env.local, .env.production, ...
  """
  @spec ignored_file?(String.t()) :: boolean()
  def ignored_file?(name) do
    basename = Path.basename(name)
    MapSet.member?(@ignored_files, basename) or String.starts_with?(basename, ".env")
  end

  @doc """
  Returns nil if the absolute `path` may be shown to a model, otherwise
  `{:excluded, name}` naming the path segment that rules it out.

  A path outside `project_dir` is not this module's concern and yields
  nil: containment is Current.IntentPaths' job, and callers check it
  first.
  """
  @spec violation(Path.t(), Path.t()) :: nil | {:excluded, String.t()}
  def violation(path, project_dir) when is_binary(path) and is_binary(project_dir) do
    root = Path.expand(project_dir)

    named(path, root) || resolved(path, root)
  end

  # The path as written.
  defp named(path, root) do
    path = Path.expand(path)

    if path != root and IntentPaths.within?(path, root) do
      {dirs, [name]} = path |> Path.relative_to(root) |> Path.split() |> Enum.split(-1)

      cond do
        excluded = Enum.find(dirs, &ignored_dir?/1) -> {:excluded, excluded}
        File.dir?(path) and ignored_dir?(name) -> {:excluded, name}
        not File.dir?(path) and ignored_file?(name) -> {:excluded, name}
        true -> nil
      end
    end
  end

  # The path it actually points at, when that is somewhere else.
  defp resolved(path, root) do
    with {:ok, real_root} <- IntentPaths.realpath(root),
         {:ok, real_path} <- IntentPaths.realpath(Path.expand(path)),
         true <- real_path != Path.expand(path) do
      named(real_path, real_root)
    else
      _ -> nil
    end
  end
end
