defmodule Current.ArtifactBuilder do
  alias Current.{Artifact, Id, Intent, Workflow}
  alias Current.EffectResult

  @spec build(Workflow.t(), {Intent.t(), Current.EffectApplicator.result()}) ::
          {:ok, Artifact.t()}

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.FilePatch{} = result}) do
    body = :json.encode(%{path: result.path, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(
      workflow,
      intent,
      :file_patch_result,
      :file_patch_result,
      "file_patch_result.json",
      body,
      %{
        bytes: byte_size(body),
        content_type: "application/json",
        patched_path: result.path
      }
    )
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.Command{} = result}) do
    body =
      :json.encode(%{
        exit_code: result.exit_code,
        stdout_artifact_id: result.stdout_artifact_id,
        stderr_artifact_id: result.stderr_artifact_id,
        stdout_bytes: result.stdout_bytes,
        stderr_bytes: result.stderr_bytes,
        intent_id: intent.id
      })
      |> IO.iodata_to_binary()

    persist(workflow, intent, :command_result, :command_result, "command_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      exit_code: result.exit_code,
      stdout_artifact_id: result.stdout_artifact_id,
      stderr_artifact_id: result.stderr_artifact_id,
      stdout_bytes: result.stdout_bytes,
      stderr_bytes: result.stderr_bytes
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.WriteFile{} = result}) do
    body = :json.encode(%{path: result.path, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(workflow, intent, :write_file_result, :report, "write_file_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      written_path: result.path
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.DeleteFile{} = result}) do
    body = :json.encode(%{path: result.path, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(workflow, intent, :delete_file_result, :report, "delete_file_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      deleted_path: result.path
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.ReadFile{} = result}) do
    body = :json.encode(%{path: result.path, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(workflow, intent, :read_result, :read_result, "read_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      read_path: result.path
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.Glob{} = result}) do
    body = :json.encode(%{matches: result.matches, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(workflow, intent, :glob_result, :report, "glob_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      match_count: length(result.matches)
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.Grep{} = result}) do
    body = :json.encode(%{matches: result.matches, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(workflow, intent, :grep_result, :report, "grep_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      match_count: length(result.matches)
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.Claim{} = result}) do
    body =
      :json.encode(%{
        verified: result.verified,
        statement: result.statement,
        reason: result.reason,
        intent_id: intent.id
      })
      |> IO.iodata_to_binary()

    persist(workflow, intent, :claim_result, :claim_result, "claim_result.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json",
      verified: result.verified,
      statement: result.statement,
      reason: result.reason
    })
  end

  def build(%Workflow{} = workflow, {%Intent{} = intent, %EffectResult.Report{} = result}) do
    body =
      :json.encode(%{generated: result.generated, intent_id: intent.id}) |> IO.iodata_to_binary()

    persist(workflow, intent, :report, :report, "report.json", body, %{
      bytes: byte_size(body),
      content_type: "application/json"
    })
  end

  defp persist(workflow, intent, name, type, filename, body, metadata) do
    # SantoshTODO: Stop hardcoding
    # SantoshTODO: Figure out if a plug and play actor approach is better here
    path = "/tmp/current/#{workflow.id}/#{intent.id}/#{filename}"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    {:ok,
     %Artifact{
       id: Id.generate(),
       workflow_id: workflow.id,
       intent_id: intent.id,
       name: name,
       type: type,
       storage: %{backend: :filesystem, path: path},
       metadata: metadata,
       timestamp: DateTime.utc_now()
     }}
  end
end
