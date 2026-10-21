defmodule Current.EffectApplicatorTest do
  use ExUnit.Case, async: false

  alias Current.{EffectApplicator, Id, Intent}

  # Most tests below pass "/" as project_dir so the boundary check is
  # trivially satisfied and only the intent's own behaviour is under test.
  # The boundary itself is covered in "apply/3 - project_dir boundary".

  describe "apply/3 - edit_file" do
    setup do
      dir = System.tmp_dir!() |> Path.join("effect_applicator_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    defp edit(path, old, new, opts \\ []) do
      {:ok, old_id} = Current.BlobStore.put(old)
      {:ok, new_id} = Current.BlobStore.put(new)

      %Intent.EditFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        old_artifact_id: old_id,
        new_artifact_id: new_id,
        replace_all: Keyword.get(opts, :replace_all, false)
      }
    end

    test "replaces the text, and records before and after", %{dir: dir} do
      path = Path.join(dir, "signup.ex")
      File.write!(path, "defmodule Signup do\nend\n")

      intent =
        edit(path, "defmodule Signup do\n", "defmodule Signup do\n  def ok, do: true\n")

      assert {:ok, %Current.EffectResult.EditFile{} = result} =
               EffectApplicator.apply(intent, [], "/")

      assert result.path == path
      assert result.replacements == 1
      assert File.read!(path) == "defmodule Signup do\n  def ok, do: true\nend\n"

      assert {:ok, "defmodule Signup do\nend\n"} =
               Current.BlobStore.read(result.before_artifact_id)

      assert {:ok, after_contents} = Current.BlobStore.read(result.after_artifact_id)
      assert after_contents == File.read!(path)
    end

    test "replace_all replaces every occurrence", %{dir: dir} do
      path = Path.join(dir, "a.ex")
      File.write!(path, "foo foo foo")

      assert {:ok, %{replacements: 3}} =
               EffectApplicator.apply(edit(path, "foo", "bar", replace_all: true), [], "/")

      assert File.read!(path) == "bar bar bar"
    end

    test "returns error if the file does not exist", %{dir: dir} do
      path = Path.join(dir, "nonexistent.ex")

      assert {:error, reason} = EffectApplicator.apply(edit(path, "a", "b"), [], "/")
      assert reason =~ "file not found"
    end

    test "returns error, and leaves the file alone, if old_string is not found", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "defmodule App do\nend\n")

      assert {:error, reason} = EffectApplicator.apply(edit(path, "Nope", "x"), [], "/")
      assert reason =~ "not found in the file"
      assert File.read!(path) == "defmodule App do\nend\n"
    end

    test "returns error if old_string matches more than once", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "foo foo")

      assert {:error, reason} = EffectApplicator.apply(edit(path, "foo", "bar"), [], "/")
      assert reason =~ "matches 2 places"
      assert File.read!(path) == "foo foo"
    end
  end

  describe "apply/3 - run_command" do
    test "executes command and captures stdout" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "echo",
        args: ["hello"]
      }

      assert {:ok, %Current.EffectResult.Command{} = result} =
               EffectApplicator.apply(intent, [], "/")

      assert result.exit_code == 0
      assert result.stdout_bytes > 0

      {:ok, stdout_path} = Current.BlobStore.path_for(result.stdout_artifact_id)
      assert File.read!(stdout_path) =~ "hello"
      assert result.stderr_bytes == 0
    end

    test "executes command and captures stderr" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "cat",
        args: ["/path/to/unknown/file"]
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      assert result.exit_code > 0
      assert result.stderr_bytes > 0

      {:ok, stderr_path} = Current.BlobStore.path_for(result.stderr_artifact_id)
      assert File.read!(stderr_path) =~ "No such file or directory"
      assert result.stdout_bytes == 0
    end

    test "returns non-zero exit code without treating command failure as applicator failure" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "false",
        args: []
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      assert result.exit_code != 0
      assert result.stderr_bytes == 0
    end

    test "returns error if command is not found" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "this_command_does_not_exist_xyz",
        args: []
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "not found"
    end
  end

  describe "apply/3 - read_file" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("read_file_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads an existing file and stores contents in artifact store", %{dir: dir} do
      path = Path.join(dir, "signup.ex")
      contents = "defmodule Signup do\n  def ok, do: true\nend\n"
      File.write!(path, contents)

      intent = %Intent.ReadFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path
      }

      assert {:ok, %Current.EffectResult.ReadFile{} = result} =
               EffectApplicator.apply(intent, [], "/")

      assert result.path == path

      assert is_binary(result.contents_artifact_id)
      assert result.bytes == byte_size(contents)
      assert {:ok, contents} == Current.BlobStore.read(result.contents_artifact_id)

      {:ok, stored_path} = Current.BlobStore.path_for(result.contents_artifact_id)
      assert File.exists?(stored_path)
      assert File.read!(stored_path) == contents
    end

    test "returns error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.ex")

      intent = %Intent.ReadFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "not found"
      assert reason =~ path
    end
  end

  describe "apply/3 - write_file" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("write_file_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "creates parent dirs and writes contents", %{dir: dir} do
      path = Path.join([dir, "nested", "deep", "generated.ex"])
      contents = "defmodule Generated do\n  def ok, do: true\nend\n"
      {:ok, contents_artifact_id} = Current.BlobStore.put(contents)

      intent = %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        contents_artifact_id: contents_artifact_id
      }

      assert {:ok, %Current.EffectResult.WriteFile{} = result} =
               EffectApplicator.apply(intent, [], "/")

      assert result.path == path
      assert File.exists?(path)
      assert File.read!(path) == contents
    end

    test "returns error if file already exists", %{dir: dir} do
      path = Path.join(dir, "existing.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "original")
      contents = "new contents"
      {:ok, contents_artifact_id} = Current.BlobStore.put(contents)

      intent = %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        contents_artifact_id: contents_artifact_id
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "already exists"
      assert File.read!(path) == "original"
    end
  end

  describe "apply/3 - delete_file" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("delete_file_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "deletes an existing file", %{dir: dir} do
      path = Path.join(dir, "old.ex")
      File.write!(path, "old contents")

      intent = %Intent.DeleteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      assert %Current.EffectResult.DeleteFile{} = result
      assert result.path == path
      refute File.exists?(path)
    end

    test "succeeds if file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.ex")
      refute File.exists?(path)

      intent = %Intent.DeleteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      assert %Current.EffectResult.DeleteFile{} = result
      assert result.path == path
      refute File.exists?(path)
    end

    test "returns error when path is a directory", %{dir: dir} do
      path = Path.join(dir, "some_dir")
      File.mkdir_p!(path)

      intent = %Intent.DeleteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "not a regular file"
      assert File.dir?(path)
    end
  end

  describe "apply/3 - grep" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("grep_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns empty matches when nothing matches", %{dir: dir} do
      path = Path.join(dir, "signup.ex")

      :ok =
        File.write!(path, """
        defmodule Signup do
        def ok, do: true
        end
        """)

      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "validate_email",
        paths: [path]
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      assert %Current.EffectResult.Grep{} = result
      matches = fetch_matches(result.matches_artifact_id)
      assert matches == []
    end

    test "returns one match per matching line", %{dir: dir} do
      path = Path.join(dir, "app.ex")

      File.write!(path, """
      alpha
      beta FINDME
      gamma FINDME
      """)

      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "FINDME",
        paths: [path]
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      matches = fetch_matches(result.matches_artifact_id)

      assert [
               %Current.EffectResult.Grep.Match{line: 2, path: ^path, text: "beta FINDME"},
               %Current.EffectResult.Grep.Match{line: 3, path: ^path, text: "gamma FINDME"}
             ] = matches
    end

    test "returns one match when a single line contains pattern multiple times", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "FINDME FINDME FINDME")

      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "FINDME",
        paths: [path]
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      matches = fetch_matches(result.matches_artifact_id)

      assert [
               %Current.EffectResult.Grep.Match{
                 path: ^path,
                 line: 1,
                 text: "FINDME FINDME FINDME"
               }
             ] = matches
    end

    test "returns error when a searched file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.ex")

      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "validate_email",
        paths: [path]
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "not found"
    end
  end

  describe "apply/3 - glob" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("glob_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns matching files for a pattern", %{dir: dir} do
      File.write!(Path.join(dir, "foo.ex"), "")
      File.write!(Path.join(dir, "bar.ex"), "")
      File.write!(Path.join(dir, "baz.txt"), "")

      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: dir
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      matches = fetch_matches(result.matches_artifact_id)
      assert %Current.EffectResult.Glob{} = result
      assert length(matches) == 2
      assert Path.join(dir, "foo.ex") in matches
      assert Path.join(dir, "bar.ex") in matches
    end

    test "returns empty list when no files match", %{dir: dir} do
      File.write!(Path.join(dir, "foo.txt"), "")

      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: dir
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      matches = fetch_matches(result.matches_artifact_id)
      assert matches == []
    end

    test "matches files recursively with ** pattern", %{dir: dir} do
      subdir = Path.join(dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(dir, "top.ex"), "")
      File.write!(Path.join(subdir, "nested.ex"), "")

      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "**/*.ex",
        base_dir: dir
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      matches = fetch_matches(result.matches_artifact_id)
      assert length(matches) == 2
      assert Path.join(dir, "top.ex") in matches
      assert Path.join(subdir, "nested.ex") in matches
    end

    test "returns error when base_dir does not exist", %{dir: dir} do
      missing = Path.join(dir, "missing")

      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: missing
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "not found"
    end

    test "returns matches in sorted order", %{dir: dir} do
      :ok = File.write!(Path.join(dir, "z.ex"), "")
      :ok = File.write!(Path.join(dir, "a.ex"), "")

      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: dir
      }

      assert {:ok, result} = EffectApplicator.apply(intent, [], "/")
      matches = fetch_matches(result.matches_artifact_id)
      assert matches == [Path.join(dir, "a.ex"), Path.join(dir, "z.ex")]
    end

    test "returns error when pattern is absolute", %{dir: dir} do
      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: Path.join(dir, "*.ex"),
        base_dir: dir
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [], "/")
      assert reason =~ "relative"
    end
  end

  defp fetch_matches(artifact_id) do
    {:ok, encoded} = Current.BlobStore.read(artifact_id)
    :erlang.binary_to_term(encoded, [:safe])
  end

  describe "apply/3 - project_dir boundary" do
    setup do
      base = Path.join(System.tmp_dir!(), "ea_boundary_#{System.unique_integer([:positive])}")
      project = Path.join(base, "project")
      outside = Path.join(base, "outside")
      File.mkdir_p!(Path.join(project, "lib"))
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "top secret\n")
      on_exit(fn -> File.rm_rf!(base) end)
      %{project: project, outside: outside}
    end

    defp read_intent(path),
      do: %Intent.ReadFile{id: Id.generate(), proposal_id: Id.generate(), path: path}

    test "reads a file inside the project", %{project: project} do
      path = Path.join(project, "lib/a.ex")
      File.write!(path, "ok")
      assert {:ok, _} = EffectApplicator.apply(read_intent(path), [], project)
    end

    test "refuses a path that is lexically outside", %{project: project, outside: outside} do
      path = Path.join(outside, "secret.txt")

      assert {:error, reason} = EffectApplicator.apply(read_intent(path), [], project)
      assert reason =~ "resolves outside the project directory"
    end

    test "refuses a path that is only outside once a symlink is followed",
         %{project: project, outside: outside} do
      File.ln_s!(outside, Path.join(project, "lib/vendor"))
      path = Path.join(project, "lib/vendor/secret.txt")

      assert {:error, reason} = EffectApplicator.apply(read_intent(path), [], project)
      assert reason =~ "resolves outside the project directory"
    end

    test "refuses to write through a symlinked directory that points outside",
         %{project: project, outside: outside} do
      File.ln_s!(outside, Path.join(project, "out"))
      {:ok, blob} = Current.BlobStore.put("pwned")

      intent = %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: Path.join(project, "out/new.txt"),
        contents_artifact_id: blob
      }

      assert {:error, _reason} = EffectApplicator.apply(intent, [], project)
      refute File.exists?(Path.join(outside, "new.txt"))
    end

    test "refuses a relative path instead of resolving it", %{project: project} do
      assert {:error, reason} = EffectApplicator.apply(read_intent("lib/a.ex"), [], project)
      assert reason =~ "is not an absolute path"
    end

    test "a symlink loop is an error, not a hang", %{project: project} do
      File.ln_s!("b", Path.join(project, "a"))
      File.ln_s!("a", Path.join(project, "b"))

      assert {:error, reason} =
               EffectApplicator.apply(read_intent(Path.join(project, "a/x")), [], project)

      assert reason =~ "too many levels of symbolic links"
    end

    test "glob drops matches reached through a symlink that points outside",
         %{project: project, outside: outside} do
      File.write!(Path.join(project, "lib/inside.txt"), "")
      File.ln_s!(outside, Path.join(project, "lib/vendor"))

      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "lib/*/*.txt",
        base_dir: project
      }

      assert {:ok, %{match_count: 0}} = EffectApplicator.apply(intent, [], project)

      inside = %{intent | pattern: "lib/*.txt"}
      assert {:ok, %{match_count: 1}} = EffectApplicator.apply(inside, [], project)
    end

    test "run_command runs with project_dir as its working directory", %{project: project} do
      intent = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "pwd"}

      assert {:ok, result} = EffectApplicator.apply(intent, [], project)
      {:ok, stdout_path} = Current.BlobStore.path_for(result.stdout_artifact_id)
      {:ok, real_project} = Current.IntentPaths.realpath(project)
      assert String.trim(File.read!(stdout_path)) in [project, real_project]
    end

    test "run_command resolves a relative command path against project_dir",
         %{project: project} do
      script = Path.join(project, "bin/hello")
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/bin/sh\necho from-project\n")
      File.chmod!(script, 0o755)

      intent = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "bin/hello"}

      assert {:ok, result} = EffectApplicator.apply(intent, [], project)
      {:ok, stdout_path} = Current.BlobStore.path_for(result.stdout_artifact_id)
      assert File.read!(stdout_path) =~ "from-project"
    end
  end
end
