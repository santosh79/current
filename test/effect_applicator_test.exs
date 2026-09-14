defmodule Current.EffectApplicatorTest do
  use ExUnit.Case, async: false

  alias Current.{EffectApplicator, Id, Intent}

  describe "apply/2 - file_patch" do
    setup do
      dir = System.tmp_dir!() |> Path.join("effect_applicator_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "applies a unified diff to an existing file", %{dir: dir} do
      path = Path.join(dir, "signup.ex")
      File.write!(path, "defmodule Signup do\nend\n")

      diff =
        [
          "--- signup.ex",
          "+++ signup.ex",
          "@@ -1,2 +1,3 @@",
          " defmodule Signup do",
          "+  def validate_email(email), do: String.contains?(email, \"@\")",
          " end",
          ""
        ]
        |> Enum.join("\n")

      {:ok, diff_artifact_id} = Current.BlobStore.put(diff)

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        diff_artifact_id: diff_artifact_id
      }

      assert !String.contains?(File.read!(path), "def validate_email")

      assert {:ok, %Current.EffectResult.FilePatch{} = result} =
               EffectApplicator.apply(intent, [])

      assert result.path == path
      assert File.read!(path) =~ "def validate_email"
    end

    test "returns error if the file does not exist", %{dir: dir} do
      non_existent_path = Path.join(dir, "nonexistent.ex")
      diff_contents = "--- a\n+++ b\n"
      {:ok, diff_artifact_id} = Current.BlobStore.put(diff_contents)

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: non_existent_path,
        diff_artifact_id: diff_artifact_id
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "not found" or reason =~ "no such file"
    end

    test "returns error if the diff does not apply cleanly", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "defmodule App do\nend\n")
      {:ok, diff_artifact_id} = Current.BlobStore.put(bad_diff())

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        diff_artifact_id: diff_artifact_id
      }

      assert {:error, _reason} = EffectApplicator.apply(intent, [])
    end
  end

  describe "apply/2 - run_command" do
    test "executes command and captures stdout" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "echo",
        args: ["hello"]
      }

      assert {:ok, %Current.EffectResult.Command{} = result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "not found"
    end
  end

  describe "apply/2 - read_file" do
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

      assert {:ok, %Current.EffectResult.ReadFile{} = result} = EffectApplicator.apply(intent, [])
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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "not found"
      assert reason =~ path
    end
  end

  describe "apply/2 - write_file" do
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
               EffectApplicator.apply(intent, [])

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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "already exists"
      assert File.read!(path) == "original"
    end
  end

  describe "apply/2 - delete_file" do
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "not a regular file"
      assert File.dir?(path)
    end
  end

  describe "apply/2 - grep" do
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "not found"
    end
  end

  describe "apply/2 - glob" do
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
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

      assert {:ok, result} = EffectApplicator.apply(intent, [])
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

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "relative"
    end
  end

  defp bad_diff do
    [
      "--- app.ex",
      "+++ app.ex",
      "@@ -1,2 +1,3 @@",
      " defmodule WrongModule do",
      "+  def bad, do: true",
      " end"
    ]
    |> Enum.join("\n")
  end

  defp fetch_matches(artifact_id) do
    {:ok, encoded} = Current.BlobStore.read(artifact_id)
    :erlang.binary_to_term(encoded)
  end
end
