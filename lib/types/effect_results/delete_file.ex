defmodule Current.EffectResult.DeleteFile do
  @enforce_keys [:path, :before_artifact_id]
  defstruct [:path, :before_artifact_id]

  @type t :: %__MODULE__{
          path: String.t(),
          before_artifact_id: Current.Id.t() | nil
        }
end

