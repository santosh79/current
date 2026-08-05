defmodule Current.Event.ArtifactProduced do
  @enforce_keys [:id, :workflow_id, :intent, :result, :artifact, :timestamp]
  defstruct [:id, :workflow_id, :intent, :result, :artifact, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent: Current.Intent.t(),
          result: Current.EffectApplicator.result(),
          artifact: Current.Artifact.t(),
          timestamp: DateTime.t()
        }
end
