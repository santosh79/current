defmodule Current.Event.EffectApplied do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :intent, :result, :timestamp]
  defstruct [:id, :workflow_id, :intent, :result, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent: Current.Intent.t(),
          result: Current.EffectApplicator.result(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
