defmodule Current.IntentValidatorTest do
  use ExUnit.Case, async: false

  alias Current.{BlobStore, Id, Intent, IntentValidator, Proposal}
  alias Current.Error.ValidationError

  defp proposal(intents) do
    %Proposal{id: Id.generate(), workflow_id: Id.generate(), intents: intents}
  end

  defp tmp_file!(contents \\ "contents") do
    path =
      Path.join(System.tmp_dir!(), "intent_validator_test_#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "validate/2 - top level" do
    test "an empty intent list is valid" do
      assert :ok = IntentValidator.validate(proposal([]), "/")
    end

    test "stops at the first invalid intent" do
      good = %Intent.Report{id: Id.generate(), proposal_id: Id.generate()}
      bad = %Intent.ReadFile{id: Id.generate(), proposal_id: Id.generate(), path: "/nope"}

      assert {:error, %ValidationError{intent_id: id}} =
               IntentValidator.validate(proposal([good, bad]), "/")

      assert id == bad.id
    end
  end

  # The per-intent tests below pass "/" as project_dir so containment is
  # trivially satisfied and only the intent's own rules are under test.
  describe "validate/2 - project_dir containment" do
    setup do
      root = Path.join(System.tmp_dir!(), "iv_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    defp delete(path),
      do: %Intent.DeleteFile{id: Id.generate(), proposal_id: Id.generate(), path: path}

    test "accepts an absolute path inside project_dir", %{root: root} do
      assert :ok = IntentValidator.validate(proposal([delete(Path.join(root, "a.ex"))]), root)
    end

    test "rejects an absolute path outside project_dir", %{root: root} do
      assert {:error, %ValidationError{reason: reason, details: %{field: :path}}} =
               IntentValidator.validate(proposal([delete("/etc/passwd")]), root)

      assert reason =~ "outside the project directory"
    end

    test "rejects a path that climbs out with '..' even if it starts inside", %{root: root} do
      sneaky = Path.join([root, "lib", "..", "..", "outside.ex"])

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([delete(sneaky)]), root)

      assert reason =~ "outside the project directory"
    end

    test "rejects a sibling directory that merely shares a name prefix", %{root: root} do
      assert {:error, %ValidationError{}} =
               IntentValidator.validate(proposal([delete(root <> "_evil/a.ex")]), root)
    end

    test "rejects a relative path rather than resolving it against the cwd", %{root: root} do
      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([delete("lib/a.ex")]), root)

      assert reason =~ "must be an absolute path"
    end

    test "checks every grep path", %{root: root} do
      file = Path.join(root, "a.ex")
      File.write!(file, "x")

      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "x",
        paths: [file, "/etc/hosts"]
      }

      assert {:error, %ValidationError{details: %{field: :paths, path: "/etc/hosts"}}} =
               IntentValidator.validate(proposal([intent]), root)
    end

    test "rejects a glob pattern that climbs out with '..'", %{root: root} do
      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "../**/*.ex",
        base_dir: root
      }

      assert {:error, %ValidationError{details: %{field: :pattern}}} =
               IntentValidator.validate(proposal([intent]), root)
    end
  end

  describe "validate/2 - read_file" do
    test "passes when the path exists" do
      path = tmp_file!()
      intent = %Intent.ReadFile{id: Id.generate(), proposal_id: Id.generate(), path: path}
      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails when the path does not exist" do
      intent = %Intent.ReadFile{id: Id.generate(), proposal_id: Id.generate(), path: "/nope"}

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "does not exist"
    end
  end

  describe "validate/2 - write_file" do
    test "passes when contents_artifact_id resolves" do
      {:ok, blob_id} = BlobStore.put("hello")

      intent = %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: "/tmp/whatever.ex",
        contents_artifact_id: blob_id
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails when contents_artifact_id does not resolve" do
      intent = %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: "/tmp/whatever.ex",
        contents_artifact_id: "sha256:" <> String.duplicate("a", 64)
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "contents blob does not exist"
    end

    test "does not check whether the target path already exists" do
      {:ok, blob_id} = BlobStore.put("hello")
      existing = tmp_file!()

      intent = %Intent.WriteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: existing,
        contents_artifact_id: blob_id
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end
  end

  describe "validate/2 - delete_file" do
    test "passes for a non-empty path, regardless of existence" do
      intent = %Intent.DeleteFile{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: "/does/not/exist"
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails for an empty path" do
      intent = %Intent.DeleteFile{id: Id.generate(), proposal_id: Id.generate(), path: ""}

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "non-empty"
    end
  end

  describe "validate/2 - file_patch" do
    test "passes when path exists and diff blob resolves" do
      path = tmp_file!()
      {:ok, diff_id} = BlobStore.put("--- a\n+++ b\n")

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        diff_artifact_id: diff_id
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails when path does not exist" do
      {:ok, diff_id} = BlobStore.put("--- a\n+++ b\n")

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: "/nope",
        diff_artifact_id: diff_id
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "path does not exist"
    end

    test "fails when diff blob does not resolve" do
      path = tmp_file!()

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: path,
        diff_artifact_id: "sha256:" <> String.duplicate("a", 64)
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "diff blob does not exist"
    end
  end

  describe "validate/2 - run_command" do
    test "passes for a non-empty cmd and string args" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "echo",
        args: ["hi"]
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "does not check whether cmd is on PATH" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "this_definitely_does_not_exist_xyz"
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails for an empty cmd" do
      intent = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: ""}

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "non-empty"
    end

    test "fails when args contains a non-string" do
      intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "echo",
        args: [1]
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "list of strings"
    end
  end

  describe "validate/2 - grep" do
    test "passes when every path exists" do
      path = tmp_file!()

      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "x",
        paths: [path]
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails when a path does not exist" do
      intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "x",
        paths: ["/nope"]
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "does not exist"
    end
  end

  describe "validate/2 - glob" do
    test "passes for a relative pattern and existing base_dir" do
      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: File.cwd!()
      }

      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end

    test "fails for an absolute pattern" do
      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "/abs/*.ex",
        base_dir: File.cwd!()
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "relative"
    end

    test "fails for a nonexistent base_dir" do
      intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: "/nope"
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "base_dir does not exist"
    end
  end

  describe "validate/2 - claim" do
    test "fails when evidence is nil" do
      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "x",
        evidence: nil
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "requires evidence"
    end

    test "fails when evidence has no source_intent_id" do
      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "x",
        evidence: %{condition: :exit_code_equals, value: 0}
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([intent]), "/")

      assert reason =~ "source_intent_id"
    end

    test "passes when source_intent_id references an earlier intent" do
      cmd = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "echo"}

      claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "x",
        evidence: %{source_intent_id: cmd.id, condition: :exit_code_equals, value: 0}
      }

      assert :ok = IntentValidator.validate(proposal([cmd, claim]), "/")
    end

    test "fails when source_intent_id references a later intent" do
      cmd = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "echo"}

      claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "x",
        evidence: %{source_intent_id: cmd.id, condition: :exit_code_equals, value: 0}
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([claim, cmd]), "/")

      assert reason =~ "does not precede it"
    end

    test "fails when source_intent_id references no intent at all" do
      claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "x",
        evidence: %{source_intent_id: Id.generate(), condition: :exit_code_equals, value: 0}
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([claim]), "/")

      assert reason =~ "does not precede it"
    end
  end

  describe "validate/2 - claim condition/intent-type compatibility" do
    test "passes when condition matches the referenced intent's result type" do
      cmd = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "echo"}
      grep = %Intent.Grep{id: Id.generate(), proposal_id: Id.generate(), pattern: "x", paths: []}

      glob = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: File.cwd!()
      }

      exit_code_claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "exit code",
        evidence: %{source_intent_id: cmd.id, condition: :exit_code_equals, value: 0}
      }

      match_equals_claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "match equals",
        evidence: %{source_intent_id: grep.id, condition: :match_count_equals, value: 1}
      }

      grep_greater_claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "grep greater",
        evidence: %{source_intent_id: grep.id, condition: :match_count_greater_than, value: 0}
      }

      glob_greater_claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "glob greater",
        evidence: %{source_intent_id: glob.id, condition: :match_count_greater_than, value: 0}
      }

      assert :ok = IntentValidator.validate(proposal([cmd, exit_code_claim]), "/")
      assert :ok = IntentValidator.validate(proposal([grep, match_equals_claim]), "/")
      assert :ok = IntentValidator.validate(proposal([grep, grep_greater_claim]), "/")
      assert :ok = IntentValidator.validate(proposal([glob, glob_greater_claim]), "/")
    end

    test "fails when the condition can never apply to the referenced intent's result type" do
      grep = %Intent.Grep{id: Id.generate(), proposal_id: Id.generate(), pattern: "x", paths: []}

      claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "impossible",
        evidence: %{source_intent_id: grep.id, condition: :exit_code_equals, value: 0}
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([grep, claim]), "/")

      assert reason =~ "can never be evaluated"
    end

    test "fails when :match_count_equals references a run_command, not a grep" do
      cmd = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "echo"}

      claim = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "impossible",
        evidence: %{source_intent_id: cmd.id, condition: :match_count_equals, value: 1}
      }

      assert {:error, %ValidationError{reason: reason}} =
               IntentValidator.validate(proposal([cmd, claim]), "/")

      assert reason =~ "can never be evaluated"
    end
  end

  describe "validate/2 - report" do
    test "always passes" do
      intent = %Intent.Report{id: Id.generate(), proposal_id: Id.generate()}
      assert :ok = IntentValidator.validate(proposal([intent]), "/")
    end
  end

  describe "completeness" do
    test "every known intent module has an explicit validation clause" do
      dummies = %{
        Intent.ReadFile => %Intent.ReadFile{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: "/nope"
        },
        Intent.WriteFile => %Intent.WriteFile{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: "/nope",
          contents_artifact_id: "sha256:" <> String.duplicate("a", 64)
        },
        Intent.DeleteFile => %Intent.DeleteFile{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: "/nope"
        },
        Intent.FilePatch => %Intent.FilePatch{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: "/nope",
          diff_artifact_id: "sha256:" <> String.duplicate("a", 64)
        },
        Intent.RunCommand => %Intent.RunCommand{
          id: Id.generate(),
          proposal_id: Id.generate(),
          cmd: "echo"
        },
        Intent.Grep => %Intent.Grep{
          id: Id.generate(),
          proposal_id: Id.generate(),
          pattern: "x",
          paths: []
        },
        Intent.Glob => %Intent.Glob{
          id: Id.generate(),
          proposal_id: Id.generate(),
          pattern: "*.ex"
        },
        Intent.Claim => %Intent.Claim{
          id: Id.generate(),
          proposal_id: Id.generate(),
          statement: "x"
        },
        Intent.Report => %Intent.Report{id: Id.generate(), proposal_id: Id.generate()}
      }

      assert Enum.sort(Map.keys(dummies)) == Enum.sort(Intent.modules()),
             "this test's dummy fixtures and Intent.modules/0 have drifted apart"

      Enum.each(Intent.modules(), fn mod ->
        intent = Map.fetch!(dummies, mod)

        # Must not raise -- every intent type needs its own validate_intent/2
        # clause, whatever it decides. What it decides is covered elsewhere.
        assert match?(:ok, IntentValidator.validate(proposal([intent]), "/")) or
                 match?(
                   {:error, %ValidationError{}},
                   IntentValidator.validate(proposal([intent]), "/")
                 )
      end)
    end
  end
end
