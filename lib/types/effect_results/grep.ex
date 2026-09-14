defmodule Current.EffectResult.Grep do
  @enforce_keys [:matches_artifact_id, :match_count, :searched_artifact_ids]
  defstruct [:matches_artifact_id, :match_count, :searched_artifact_ids]

  @type t :: %__MODULE__{
          matches_artifact_id: Current.Id.t(),
          match_count: non_neg_integer(),
          searched_artifact_ids: [Current.Id.t()]
        }
end
