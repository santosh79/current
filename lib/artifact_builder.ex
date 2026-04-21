defmodule Current.ArtifactBuilder do
  alias Current.{Artifact, Id, Intent, Workflow}

  @spec build(Workflow.t(), {Intent.t(), map()}) :: {:ok, Artifact.t()}
  def build(%Workflow{} = workflow, {%Intent{} = intent, result}) do
    {name, type, path_suffix} =
      case intent.type do
        :file_patch ->
          {:file_patch_result, :file_patch_result, "file_patch_result.json"}

        :write_file ->
          {:write_file_result, :report, "write_file_result.json"}

        :delete_file ->
          {:delete_file_result, :report, "delete_file_result.json"}

        :run_command ->
          {:command_result, :command_result, "command_result.json"}

        :read_file ->
          {:read_result, :read_result, "read_result.json"}

        :glob ->
          {:glob_result, :report, "glob_result.json"}

        :grep ->
          {:grep_result, :report, "grep_result.json"}

        :claim ->
          {:claim_result, :claim_result, "claim_result.json"}

        :report ->
          {:report, :report, "report.json"}
      end

    # SantoshTODO: Figure out a proper dir to store this in, ideally coming from config
    path = "/tmp/current/#{workflow.id}/#{intent.id}/#{path_suffix}"
    body = inspect(%{intent: intent, result: result}, pretty: true)

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
       metadata: %{
         bytes: byte_size(body),
         content_type: "text/plain"
       },
       timestamp: DateTime.utc_now()
     }}
  end
end
