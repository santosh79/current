defmodule Current.EffectResult.EditFile do
  @enforce_keys [:path, :before_artifact_id, :after_artifact_id, :replacements]
  defstruct [:path, :before_artifact_id, :after_artifact_id, :replacements]

  @type t :: %__MODULE__{
          path: String.t(),
          before_artifact_id: Current.Id.t(),
          after_artifact_id: Current.Id.t(),
          replacements: pos_integer()
        }
end
