defmodule Current.ArtifactBuilderTest do
  use ExUnit.Case, async: false

  alias Current.{ArtifactBuilder, Id, Intent, Workflow}
  alias Current.EffectResult

  defp workflow_fixture do
    now = DateTime.utc_now()

    %Workflow{
      id: Id.generate(),
      task_id: Id.generate(),
      status: :applying,
      proposal: nil,
      result: nil,
      events: [],
      started_at: now,
      created_at: now,
      completed_at: nil,
      updated_at: now,
      error: nil
    }
  end

  defp intent_fixture(type, payload) do
    case type do
      :file_patch ->
        %Intent.FilePatch{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: Map.get(payload, :path),
          diff: Map.get(payload, :diff)
        }

      :write_file ->
        %Intent.WriteFile{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: Map.get(payload, :path),
          contents: Map.get(payload, :contents)
        }

      :delete_file ->
        %Intent.DeleteFile{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: Map.get(payload, :path)
        }

      :read_file ->
        %Intent.ReadFile{
          id: Id.generate(),
          proposal_id: Id.generate(),
          path: Map.get(payload, :path)
        }

      :glob ->
        %Intent.Glob{
          id: Id.generate(),
          proposal_id: Id.generate(),
          pattern: Map.get(payload, :pattern),
          base_dir: Map.get(payload, :base_dir, ".")
        }

      :grep ->
        %Intent.Grep{
          id: Id.generate(),
          proposal_id: Id.generate(),
          pattern: Map.get(payload, :pattern),
          paths: Map.get(payload, :paths)
        }

      :claim ->
        %Intent.Claim{
          id: Id.generate(),
          proposal_id: Id.generate(),
          statement: Map.get(payload, :statement),
          evidence: Map.get(payload, :evidence),
          expected: Map.get(payload, :expected)
        }

      :run_command ->
        %Intent.RunCommand{
          id: Id.generate(),
          proposal_id: Id.generate(),
          cmd: Map.get(payload, :cmd),
          args: Map.get(payload, :args, [])
        }

      :report ->
        %Intent.Report{
          id: Id.generate(),
          proposal_id: Id.generate(),
          summary: Map.get(payload, :summary)
        }
    end
  end

  describe "build/2 - file_patch" do
    test "constructs a file_patch_result artifact" do
      workflow = workflow_fixture()

      intent = %Intent.FilePatch{
        id: Id.generate(),
        proposal_id: Id.generate(),
        path: "lib/app.ex",
        diff: "..."
      }

      result = %EffectResult.FilePatch{path: "lib/app.ex"}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.workflow_id == workflow.id
      assert artifact.intent_id == intent.id
      assert artifact.name == :file_patch_result
      assert artifact.type == :file_patch_result
      assert artifact.storage.backend == :filesystem
      assert String.ends_with?(artifact.storage.path, "file_patch_result.json")
      assert File.exists?(artifact.storage.path)
      assert artifact.metadata.content_type == "application/json"
      assert artifact.metadata.bytes > 0
      assert artifact.metadata.patched_path == "lib/app.ex"
    end

    test "writes artifact under workflow and intent specific path" do
      workflow = workflow_fixture()
      intent = intent_fixture(:file_patch, %{path: "lib/my_app/signup.ex", diff: "...diff..."})
      result = %EffectResult.FilePatch{path: "lib/my_app/signup.ex"}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.storage.path ==
               "/tmp/current/#{workflow.id}/#{intent.id}/file_patch_result.json"
    end
  end

  describe "build/2 - run_command" do
    test "constructs a command_result artifact with stdout and stderr artifact ids" do
      workflow = workflow_fixture()
      intent = intent_fixture(:run_command, %{cmd: "mix test", args: []})

      stdout_id = Id.generate()
      stderr_id = Id.generate()

      result = %EffectResult.Command{
        exit_code: 0,
        stdout_artifact_id: stdout_id,
        stderr_artifact_id: stderr_id,
        stdout_bytes: 42,
        stderr_bytes: 0
      }

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :command_result
      assert artifact.type == :command_result
      assert artifact.storage.backend == :filesystem
      assert String.ends_with?(artifact.storage.path, "command_result.json")
      assert File.exists?(artifact.storage.path)
      assert artifact.metadata.exit_code == 0
      assert artifact.metadata.stdout_artifact_id == stdout_id
      assert artifact.metadata.stderr_artifact_id == stderr_id
      assert artifact.metadata.stdout_bytes == 42
      assert artifact.metadata.stderr_bytes == 0
      assert artifact.metadata.content_type == "application/json"
    end

    test "artifact file contains structured json with exit code and artifact references" do
      workflow = workflow_fixture()
      intent = intent_fixture(:run_command, %{cmd: "echo hello", args: []})

      stdout_id = Id.generate()
      stderr_id = Id.generate()

      result = %EffectResult.Command{
        exit_code: 0,
        stdout_artifact_id: stdout_id,
        stderr_artifact_id: stderr_id,
        stdout_bytes: 12,
        stderr_bytes: 0
      }

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      body = File.read!(artifact.storage.path)
      parsed = :json.decode(body)

      assert parsed["exit_code"] == 0
      assert parsed["stdout_artifact_id"] == stdout_id
      assert parsed["stderr_artifact_id"] == stderr_id
    end
  end

  describe "build/2 - write_file" do
    test "constructs a write_file_result artifact" do
      workflow = workflow_fixture()
      intent = intent_fixture(:write_file, %{path: "lib/app.ex", contents: "hello"})
      result = %EffectResult.WriteFile{path: "lib/app.ex"}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :write_file_result
      assert artifact.type == :report
      assert artifact.metadata.written_path == "lib/app.ex"
    end
  end

  describe "build/2 - delete_file" do
    test "constructs a delete_file_result artifact" do
      workflow = workflow_fixture()
      intent = intent_fixture(:delete_file, %{path: "lib/old.ex"})
      result = %EffectResult.DeleteFile{path: "lib/old.ex"}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :delete_file_result
      assert artifact.type == :report
      assert artifact.metadata.deleted_path == "lib/old.ex"
    end
  end

  describe "build/2 - read_file" do
    test "constructs a read_result artifact" do
      workflow = workflow_fixture()
      intent = intent_fixture(:read_file, %{path: "lib/app.ex"})

      {:ok, contents_artifact_id} = Current.ArtifactStore.put("defmodule App do\nend\n")

      result = %EffectResult.ReadFile{
        path: "lib/app.ex",
        contents_artifact_id: contents_artifact_id,
        bytes: 22
      }

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :read_result
      assert artifact.type == :read_result
      assert artifact.metadata.read_path == "lib/app.ex"
    end
  end

  describe "build/2 - glob" do
    test "constructs a glob_result artifact with match count" do
      workflow = workflow_fixture()
      intent = intent_fixture(:glob, %{pattern: "lib/**/*.ex"})
      result = %EffectResult.Glob{matches: ["lib/a.ex", "lib/b.ex"]}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :glob_result
      assert artifact.type == :report
      assert artifact.metadata.match_count == 2
    end
  end

  describe "build/2 - grep" do
    test "constructs a grep_result artifact with match count" do
      workflow = workflow_fixture()
      intent = intent_fixture(:grep, %{pattern: "defmodule"})
      result = %EffectResult.Grep{matches: ["lib/a.ex:1:defmodule A"]}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :grep_result
      assert artifact.type == :report
      assert artifact.metadata.match_count == 1
    end
  end

  describe "build/2 - claim" do
    test "constructs a claim_result artifact with verified flag and statement" do
      workflow = workflow_fixture()
      intent = intent_fixture(:claim, %{statement: "tests pass"})

      result = %EffectResult.Claim{
        verified: true,
        statement: "tests pass",
        reason: "asserted directly"
      }

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :claim_result
      assert artifact.type == :claim_result
      assert artifact.metadata.verified == true
      assert artifact.metadata.statement == "tests pass"
      assert artifact.metadata.reason == "asserted directly"
    end
  end

  describe "build/2 - report" do
    test "constructs a report artifact" do
      workflow = workflow_fixture()
      intent = intent_fixture(:report, %{summary: "finished"})
      result = %EffectResult.Report{generated: true}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.name == :report
      assert artifact.type == :report
    end

    test "metadata bytes matches persisted file size" do
      workflow = workflow_fixture()
      intent = intent_fixture(:report, %{summary: "finished"})
      result = %EffectResult.Report{generated: true}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      {:ok, stat} = File.stat(artifact.storage.path)
      assert artifact.metadata.bytes == stat.size
    end
  end
end
