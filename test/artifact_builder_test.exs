defmodule Current.ArtifactBuilderTest do
  use ExUnit.Case, async: false

  alias Current.{ArtifactBuilder, Id, Intent, Workflow}

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
    %Intent{
      id: Id.generate(),
      proposal_id: Id.generate(),
      type: type,
      payload: payload
    }
  end

  describe "build/2" do
    test "constructs artifact for each supported intent type" do
      workflow = workflow_fixture()

      cases = [
        {:file_patch, %{path: "lib/app.ex", diff: "..."},
         :file_patch_result, :file_patch_result, "file_patch_result.json"},
        {:write_file, %{path: "lib/app.ex", contents: "hello"},
         :write_file_result, :report, "write_file_result.json"},
        {:delete_file, %{path: "lib/app.ex"},
         :delete_file_result, :report, "delete_file_result.json"},
        {:run_command, %{command: "mix test"},
         :command_result, :command_result, "command_result.json"},
        {:read_file, %{path: "lib/app.ex"},
         :read_result, :read_result, "read_result.json"},
        {:glob, %{pattern: "lib/**/*.ex"},
         :glob_result, :report, "glob_result.json"},
        {:grep, %{pattern: "defmodule"},
         :grep_result, :report, "grep_result.json"},
        {:claim, %{claim: "tests pass"},
         :claim_result, :claim_result, "claim_result.json"},
        {:report, %{summary: "done"},
         :report, :report, "report.json"}
      ]

      Enum.each(cases, fn {intent_type, payload, expected_name, expected_type, expected_suffix} ->
        intent = intent_fixture(intent_type, payload)
        result = %{ok: true, source: intent_type}

        {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

        assert artifact.workflow_id == workflow.id
        assert artifact.intent_id == intent.id
        assert artifact.name == expected_name
        assert artifact.type == expected_type
        assert artifact.storage.backend == :filesystem
        assert String.ends_with?(artifact.storage.path, expected_suffix)
        assert File.exists?(artifact.storage.path)

        assert is_map(artifact.metadata)
        assert artifact.metadata.bytes > 0
        assert artifact.metadata.content_type == "text/plain"

        contents = File.read!(artifact.storage.path)
        assert contents =~ Atom.to_string(intent_type)
      end)
    end

    test "writes artifact under workflow and intent specific path" do
      workflow = workflow_fixture()
      intent = intent_fixture(:file_patch, %{path: "lib/my_app/signup.ex", diff: "...diff..."})
      result = %{path: "lib/my_app/signup.ex"}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      assert artifact.storage.path ==
               "/tmp/current/#{workflow.id}/#{intent.id}/file_patch_result.json"
    end

    test "metadata bytes matches persisted file size" do
      workflow = workflow_fixture()
      intent = intent_fixture(:report, %{summary: "finished"})
      result = %{generated: true}

      {:ok, artifact} = ArtifactBuilder.build(workflow, {intent, result})

      {:ok, stat} = File.stat(artifact.storage.path)
      assert artifact.metadata.bytes == stat.size
    end
  end
end
