defmodule Current.EffectApplicatorTest do
  use ExUnit.Case, async: false

  alias Current.{EffectApplicator, Id, Intent}

  defp intent_fixture(type, payload) do
    %Intent{
      id: Id.generate(),
      proposal_id: Id.generate(),
      type: type,
      payload: payload
    }
  end

  describe "apply/1 - file_patch" do
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

      intent = intent_fixture(:file_patch, %{path: path, diff: diff})
      assert {:ok, result} = EffectApplicator.apply(intent)

      assert result.path == path
      contents = File.read!(path)
      assert contents =~ "def validate_email"
    end

    test "returns error if the file does not exist", %{dir: dir} do
      path = Path.join(dir, "nonexistent.ex")
      intent = intent_fixture(:file_patch, %{path: path, diff: "--- a\n+++ b\n"})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "not found" or reason =~ "no such file"
    end

    test "returns error if the diff does not apply cleanly", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "defmodule App do\nend\n")

      intent = intent_fixture(:file_patch, %{path: path, diff: bad_diff()})
      assert {:error, _reason} = EffectApplicator.apply(intent)
    end
  end

  describe "apply/1 - unsupported intent type" do
    test "returns error with descriptive message" do
      intent = intent_fixture(:drop_database, %{})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "unsupported intent type"
      assert reason =~ "drop_database"
    end

    test "error message includes the actual intent type" do
      intent = intent_fixture(:launch_missiles, %{})
      {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "launch_missiles"
    end
  end

  describe "apply/1 - run_command" do
    test "executes command and captures stdout" do
      intent = intent_fixture(:run_command, %{cmd: "echo", args: ["hello"]})
      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.exit_code == 0
      assert result.stdout_bytes > 0

      {:ok, stdout_path} = Current.ArtifactStore.path_for(result.stdout_artifact_id)
      stdout = File.read!(stdout_path)

      assert stdout =~ "hello"

      assert result.stderr_bytes == 0
    end

    test "executes command and captures stderr" do
      path_to_unknown_file = "/path/to/unknown/file"
      intent = intent_fixture(:run_command, %{cmd: "cat", args: [path_to_unknown_file]})
      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.exit_code > 0

      assert result.stderr_bytes > 0
      {:ok, stderr_path} = Current.ArtifactStore.path_for(result.stderr_artifact_id)
      stderr = File.read!(stderr_path)
      assert stderr =~ "No such file or directory"

      assert result.stdout_bytes == 0
    end

    test "returns non-zero exit code without treating command failure as applicator failure" do
      intent = intent_fixture(:run_command, %{cmd: "false", args: []})

      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.exit_code != 0
      assert result.stderr_bytes == 0
    end

    test "returns error if command is not found" do
      intent = intent_fixture(:run_command, %{cmd: "this_command_does_not_exist_xyz", args: []})

      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "not found"
    end
  end

  describe "apply/1 - write_file" do
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

      intent =
        intent_fixture(:write_file, %{
          path: path,
          contents: contents
        })

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert %Current.EffectResult.WriteFile{} = result
      assert result.path == path

      assert File.exists?(path)
      assert File.read!(path) == contents
    end

    test "returns error if file already exists", %{dir: dir} do
      path = Path.join(dir, "existing.ex")

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "original")

      intent =
        intent_fixture(:write_file, %{
          path: path,
          contents: "new contents"
        })

      assert {:error, reason} = EffectApplicator.apply(intent)

      assert reason =~ "already exists"

      # original contents preserved
      assert File.read!(path) == "original"
    end
  end

  describe "apply/1 - delete_file" do
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

      intent = intent_fixture(:delete_file, %{path: path})

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert %Current.EffectResult.DeleteFile{} = result
      assert result.path == path
      refute File.exists?(path)
    end

    test "succeeds if file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.ex")

      intent = intent_fixture(:delete_file, %{path: path})

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert %Current.EffectResult.DeleteFile{} = result
      assert result.path == path
      refute File.exists?(path)
    end

    test "returns error when path is a directory", %{dir: dir} do
      path = Path.join(dir, "some_dir")
      File.mkdir_p!(path)

      intent = intent_fixture(:delete_file, %{path: path})

      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "not a regular file"
      assert File.dir?(path)
    end
  end

  describe "apply/1 - grep" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("grep_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "returns matching lines from files", %{dir: dir} do
      path = Path.join(dir, "signup.ex")

      File.write!(path, """
      defmodule Signup do
        def validate_email(email), do: String.contains?(email, "@")
        def ok, do: true
      end
      """)

      intent =
        intent_fixture(:grep, %{
          pattern: "validate_email",
          paths: [path]
        })

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert %Current.EffectResult.Grep{} = result
      assert length(result.matches) == 1

      [match] = result.matches

      assert match.path == path
      assert match.line == 2
      assert match.text =~ "validate_email"
    end

    test "returns empty matches when nothing matches", %{dir: dir} do
      path = Path.join(dir, "signup.ex")

      File.write!(path, """
      defmodule Signup do
        def ok, do: true
      end
      """)

      intent =
        intent_fixture(:grep, %{
          pattern: "validate_email",
          paths: [path]
        })

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert %Current.EffectResult.Grep{} = result
      assert result.matches == []
    end

    test "returns one match per matching line", %{dir: dir} do
      path = Path.join(dir, "app.ex")

      File.write!(path, """
      alpha
      beta TODO
      gamma TODO
      """)

      intent = intent_fixture(:grep, %{pattern: "TODO", paths: [path]})

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert [
               %Current.EffectResult.Grep.Match{
                 line: 2,
                 path: ^path,
                 text: "beta TODO"
               },
               %Current.EffectResult.Grep.Match{
                 line: 3,
                 path: ^path,
                 text: "gamma TODO"
               }
             ] = result.matches
    end

    test "returns one match when a single line contains pattern multiple times", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "TODO TODO TODO")

      intent = intent_fixture(:grep, %{pattern: "TODO", paths: [path]})

      assert {:ok, result} = EffectApplicator.apply(intent)

      assert [%Current.EffectResult.Grep.Match{path: ^path, line: 1, text: "TODO TODO TODO"}] =
               result.matches
    end

    test "returns error when a searched file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.ex")

      intent =
        intent_fixture(:grep, %{
          pattern: "validate_email",
          paths: [path]
        })

      assert {:error, reason} = EffectApplicator.apply(intent)

      assert reason =~ "not found"
    end
  end

  defp bad_diff() do
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
end
