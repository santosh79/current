defmodule Current.Event.ArtifactsProduced do
  @enforce_keys [:id, :workflow_id, :workflow, :artifacts, :timestamp]
  defstruct [:id, :workflow_id, :workflow, :artifacts, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          workflow: Current.Workflow.t(),
          artifacts: [Current.Artifact.t()],
          timestamp: DateTime.t()
        }
end
