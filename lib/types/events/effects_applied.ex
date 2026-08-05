defmodule Current.Event.EffectsApplied do
  @enforce_keys [:id, :workflow_id, :intent_results, :timestamp]
  defstruct [:id, :workflow_id, :intent_results, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent_results: [{Current.Intent.t(), Current.EffectApplicator.result()}],
          timestamp: DateTime.t()
        }
end
