defmodule Current.EffectResult.Glob do
  @enforce_keys [:matches_artifact_id, :match_count]
  defstruct [:matches_artifact_id, :match_count]

  @type t :: %__MODULE__{
          matches_artifact_id: Current.Id.t(),
          match_count: non_neg_integer()
        }
end
