defmodule Current.E2E.ProjectDirPathsTest do
  @moduledoc """
  Relative paths from a proposal are resolved against the task's
  project_dir before they are recorded, and paths that resolve outside
  it fail validation.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{Event, Id, Intent, Proposal}

  defmodule OnePathProposalBuilder do
    @behaviour Current.ProposalBuilder

    def set_path(path), do: :persistent_term.put({__MODULE__, :path}, path)

    @impl true
    def build(_request, workflow_id, _client_module, _timeout_ms, _project_dir) do
      proposal_id = Id.generate()

      intent = %Intent.DeleteFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: :persistent_term.get({__MODULE__, :path})
      }

      {:ok,
       %Proposal{
         id: proposal_id,
         workflow_id: workflow_id,
         intents: [intent],
         justification: "test",
         claims: [],
         dependencies: []
       }}
    end
  end

  setup do
    use_proposal_builder(OnePathProposalBuilder)

    project_dir =
      Path.join(Current.TestTmp.dir(), "current_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf!(project_dir) end)

    %{project_dir: project_dir}
  end

  # :plan mode, so nothing is ever applied -- only resolution and
  # validation are exercised.
  defp submit_with_path(path, project_dir) do
    OnePathProposalBuilder.set_path(path)
    submit!([mode: :plan], project_dir) |> await_workflow_created()
  end

  test "a relative path is recorded as absolute, under project_dir", %{project_dir: project_dir} do
    workflow_id = submit_with_path("lib/./old.ex", project_dir)

    assert %Event.ProposalProduced{proposal: %Proposal{intents: [%Intent.DeleteFile{path: path}]}} =
             await(:proposal_produced, workflow_id)

    assert path == Path.join([project_dir, "lib", "old.ex"])
    await(:proposal_validated, workflow_id)
  end

  test "a path that climbs out of project_dir fails validation", %{project_dir: project_dir} do
    workflow_id = submit_with_path("../../outside.ex", project_dir)

    %Event.ProposalValidationFailed{error: error} =
      await(:proposal_validation_failed, workflow_id)

    assert error.reason =~ "outside the project directory"
  end

  test "an absolute path elsewhere fails validation", %{project_dir: project_dir} do
    workflow_id = submit_with_path("/etc/passwd", project_dir)
    await(:proposal_validation_failed, workflow_id)
  end
end
