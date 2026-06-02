defmodule Current.EffectResult.Grep do
  @enforce_keys [:matches, :searched_artifact_ids]
  defstruct [:matches, :searched_artifact_ids]

  @type t :: %__MODULE__{
          matches: [Current.EffectResult.Grep.Match.t()],
          searched_artifact_ids: [Current.Id.t()]
        }
end
