defmodule Current.ProjectContextTest do
  use ExUnit.Case, async: true

  alias Current.ProjectContext

  setup do
    base = Path.join(System.tmp_dir!(), "project_context_#{System.unique_integer([:positive])}")
    project = Path.join(base, "project")
    outside = Path.join(base, "outside")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(outside)
    File.write!(Path.join(project, "lib/a.ex"), "defmodule A do end\n")
    File.write!(Path.join(outside, "credentials"), "AWS_SECRET=hunter2\n")
    on_exit(fn -> File.rm_rf!(base) end)
    %{project: project, outside: outside}
  end

  # The listed paths, in order.
  defp paths!(project) do
    {:ok, %{files: files}} = ProjectContext.layout(project)
    Enum.map(files, & &1.path)
  end

  test "lists regular files by project-relative path, with their size and no contents",
       %{project: project} do
    assert {:ok, %{root: ^project, files: [%{path: "lib/a.ex", bytes: 19}], omitted: 0}} =
             ProjectContext.layout(project)
  end

  test "leaves out dependencies, build output, lockfiles and secrets", %{project: project} do
    for path <- ["node_modules/x/index.js", "_build/a.beam", ".git/config", "lib/deps/b.ex"] do
      File.mkdir_p!(Path.join(project, Path.dirname(path)))
      File.write!(Path.join(project, path), "x")
    end

    for name <- [".env", ".env.production", "mix.lock"] do
      File.write!(Path.join(project, name), "x")
    end

    assert paths!(project) == ["lib/a.ex"]
  end

  test "never lists through a symlinked directory that points outside",
       %{project: project, outside: outside} do
    File.ln_s!(outside, Path.join(project, "vendor"))
    assert paths!(project) == ["lib/a.ex"]
  end

  test "never lists a symlinked file that points outside", %{project: project, outside: outside} do
    File.ln_s!(Path.join(outside, "credentials"), Path.join(project, "creds.txt"))
    assert paths!(project) == ["lib/a.ex"]
  end

  test "lists a symlinked file that resolves inside, with its target's size",
       %{project: project} do
    File.ln_s!("lib/a.ex", Path.join(project, "alias.ex"))

    assert {:ok, %{files: [%{path: "alias.ex", bytes: 19}, %{path: "lib/a.ex"}]}} =
             ProjectContext.layout(project)
  end

  test "never lists a symlink to a secret, whatever the link is called", %{project: project} do
    File.write!(Path.join(project, ".env"), "TOKEN=hunter2\n")
    File.ln_s!(".env", Path.join(project, "settings.txt"))
    assert paths!(project) == ["lib/a.ex"]
  end

  test "does not descend into a symlinked directory even when it points inside",
       %{project: project} do
    File.ln_s!("lib", Path.join(project, "lib_link"))
    assert paths!(project) == ["lib/a.ex"]
  end

  test "symlink loops are neither followed nor fatal", %{project: project} do
    # Two self-links would branch at every level if followed (~2^40 paths).
    File.ln_s!(".", Path.join(project, "loop1"))
    File.ln_s!(".", Path.join(project, "loop2"))
    assert paths!(project) == ["lib/a.ex"]
  end

  test "skips dangling symlinks", %{project: project} do
    File.ln_s!("does_not_exist", Path.join(project, "dangling"))
    assert paths!(project) == ["lib/a.ex"]
  end

  test "skips FIFOs", %{project: project} do
    {_, 0} = System.cmd("mkfifo", [Path.join(project, "pipe")])
    assert paths!(project) == ["lib/a.ex"]
  end

  test "a missing root is an error", %{project: project} do
    missing = Path.join(project, "nope")
    assert {:error, {:not_a_directory, ^missing}} = ProjectContext.layout(missing)
  end
end
