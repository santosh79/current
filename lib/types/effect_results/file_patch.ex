defmodule Current.EffectResult.FilePatch do
  @enforce_keys [:path, :before_artifact_id, :after_artifact_id]
  defstruct [:path, :before_artifact_id, :after_artifact_id]

  @type t :: %__MODULE__{
          path: String.t(),
          before_artifact_id: Current.Id.t(),
          after_artifact_id: Current.Id.t()
        }
end
