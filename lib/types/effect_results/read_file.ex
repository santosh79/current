defmodule Current.EffectResult.ReadFile do
  @enforce_keys [:path, :contents_artifact_id, :bytes]
  defstruct [:path, :contents_artifact_id, :bytes]

  @type t :: %__MODULE__{
          path: String.t(),
          contents_artifact_id: Current.Id.t(),
          bytes: non_neg_integer()
        }
end
