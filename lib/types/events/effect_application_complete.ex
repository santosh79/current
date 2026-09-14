defmodule Current.Event.EffectApplicationComplete do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :intent_results, :timestamp]
  defstruct [:id, :workflow_id, :intent_results, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent_results: [{Current.Intent.t(), Current.EffectApplicator.result()}],
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
