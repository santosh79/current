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

  defp files!(project) do
    {:ok, %{files: files}} = ProjectContext.build(project)
    files
  end

  test "reads regular files by project-relative path", %{project: project} do
    assert files!(project) == %{"lib/a.ex" => "defmodule A do end\n"}
  end

  test "never reads through a symlinked directory that points outside",
       %{project: project, outside: outside} do
    File.ln_s!(outside, Path.join(project, "vendor"))
    refute Enum.any?(Map.values(files!(project)), &(&1 =~ "hunter2"))
  end

  test "never reads a symlinked file that points outside", %{project: project, outside: outside} do
    File.ln_s!(Path.join(outside, "credentials"), Path.join(project, "creds.txt"))
    refute Map.has_key?(files!(project), "creds.txt")
  end

  test "reads a symlinked file that resolves inside", %{project: project} do
    File.ln_s!("lib/a.ex", Path.join(project, "alias.ex"))
    assert files!(project)["alias.ex"] == "defmodule A do end\n"
  end

  test "does not descend into a symlinked directory even when it points inside",
       %{project: project} do
    File.ln_s!("lib", Path.join(project, "lib_link"))
    assert Map.keys(files!(project)) == ["lib/a.ex"]
  end

  test "symlink loops are neither followed nor fatal", %{project: project} do
    # Two self-links would branch at every level if followed (~2^40 paths).
    File.ln_s!(".", Path.join(project, "loop1"))
    File.ln_s!(".", Path.join(project, "loop2"))
    assert Map.keys(files!(project)) == ["lib/a.ex"]
  end

  test "skips dangling symlinks", %{project: project} do
    File.ln_s!("does_not_exist", Path.join(project, "dangling"))
    assert Map.keys(files!(project)) == ["lib/a.ex"]
  end

  test "skips FIFOs instead of blocking on them", %{project: project} do
    {_, 0} = System.cmd("mkfifo", [Path.join(project, "pipe")])
    assert Map.keys(files!(project)) == ["lib/a.ex"]
  end

  test "a missing root is an error", %{project: project} do
    missing = Path.join(project, "nope")
    assert {:error, {:not_a_directory, ^missing}} = ProjectContext.build(missing)
  end
end
