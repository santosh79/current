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

  describe "apply/1 - glob" do
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

      intent = intent_fixture(:glob, %{pattern: "*.ex", base_dir: dir})

      assert {:ok, result} = EffectApplicator.apply(intent)
      assert %Current.EffectResult.Glob{} = result
      assert length(result.matches) == 2
      assert Path.join(dir, "foo.ex") in result.matches
      assert Path.join(dir, "bar.ex") in result.matches
    end

    test "returns empty list when no files match", %{dir: dir} do
      File.write!(Path.join(dir, "foo.txt"), "")

      intent = intent_fixture(:glob, %{pattern: "*.ex", base_dir: dir})

      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.matches == []
    end

    test "matches files recursively with ** pattern", %{dir: dir} do
      subdir = Path.join(dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(dir, "top.ex"), "")
      File.write!(Path.join(subdir, "nested.ex"), "")

      intent = intent_fixture(:glob, %{pattern: "**/*.ex", base_dir: dir})

      assert {:ok, result} = EffectApplicator.apply(intent)
      assert length(result.matches) == 2
      assert Path.join(dir, "top.ex") in result.matches
      assert Path.join(subdir, "nested.ex") in result.matches
    end

    test "returns error when base_dir does not exist", %{dir: dir} do
      missing = Path.join(dir, "missing")

      intent = intent_fixture(:glob, %{pattern: "*.ex", base_dir: missing})

      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "not found"
    end

    test "returns matches in sorted order", %{dir: dir} do
      z_path = Path.join(dir, "z.ex")
      a_path = Path.join(dir, "a.ex")

      File.write!(z_path, "")
      File.write!(a_path, "")

      intent = intent_fixture(:glob, %{pattern: "*.ex", base_dir: dir})

      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.matches == [a_path, z_path]
    end

    test "returns error when pattern is absolute", %{dir: dir} do
      intent = intent_fixture(:glob, %{pattern: Path.join(dir, "*.ex"), base_dir: dir})

      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "relative"
    end
  end

  describe "apply/1 - claim (stage 0: expected boolean)" do
    test "returns verified true when expected is true" do
      intent = intent_fixture(:claim, %{statement: "signup validates email", expected: true})
      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.verified == true
      assert result.statement == "signup validates email"
      assert result.reason == "asserted directly"
    end

    test "returns verified false when expected is false" do
      intent = intent_fixture(:claim, %{statement: "signup validates email", expected: false})
      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.verified == false
    end

    test "returns error when neither evidence nor expected is present" do
      intent = intent_fixture(:claim, %{statement: "signup validates email"})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "evidence"
      assert reason =~ "expected"
    end

    test "returns error when expected is not boolean" do
      intent = intent_fixture(:claim, %{statement: "signup validates email", expected: "true"})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "boolean"
    end
  end

  describe "apply/2 - claim (stage 1: evidence against prior results)" do
    test "verifies grep match count greater than 0 when matches exist" do
      grep_intent = intent_fixture(:grep, %{pattern: "validate_email", paths: []})

      grep_result = %Current.EffectResult.Grep{
        matches: [
          %Current.EffectResult.Grep.Match{path: "signup.ex", line: 2, text: "def validate_email"}
        ]
      }

      prior_results = [{grep_intent, grep_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "validate_email exists in codebase",
          evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: 0}
        })

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == true
      assert result.statement == "validate_email exists in codebase"
      assert result.reason =~ "1 match"
      assert result.reason =~ "more than 0"
    end

    test "verifies grep match count fails when no matches" do
      grep_intent = intent_fixture(:grep, %{pattern: "validate_email", paths: []})
      grep_result = %Current.EffectResult.Grep{matches: []}
      prior_results = [{grep_intent, grep_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "validate_email exists in codebase",
          evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: 0}
        })

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == false
      assert result.reason =~ "0 match"
    end

    test "verifies command exit code equals 0" do
      cmd_intent = intent_fixture(:run_command, %{cmd: "mix", args: ["test"]})

      cmd_result = %Current.EffectResult.Command{
        exit_code: 0,
        stdout_artifact_id: "sha256:aaa",
        stderr_artifact_id: "sha256:bbb",
        stdout_bytes: 10,
        stderr_bytes: 0
      }

      prior_results = [{cmd_intent, cmd_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "tests pass",
          evidence: %{intent_type: :run_command, condition: :exit_code_equals, value: 0}
        })

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == true
      assert result.reason =~ "exited with 0"
    end

    test "returns error when referenced intent type has no prior result" do
      intent =
        intent_fixture(:claim, %{
          statement: "grep found something",
          evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: 0}
        })

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "grep"
      # assert reason =~ "not found"
      assert reason =~ "no such intent result found"
    end

    test "returns error for unsupported condition on result type" do
      glob_intent = intent_fixture(:glob, %{pattern: "*.ex", base_dir: "."})
      glob_result = %Current.EffectResult.Glob{matches: ["lib/app.ex"]}
      prior_results = [{glob_intent, glob_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "something",
          evidence: %{intent_type: :glob, condition: :exit_code_equals, value: 0}
        })

      assert {:error, reason} = EffectApplicator.apply(intent, prior_results)
      assert reason =~ "not supported"
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
