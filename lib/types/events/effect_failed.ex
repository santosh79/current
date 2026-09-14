defmodule Current.Event.EffectFailed do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :intent, :reason, :timestamp]
  defstruct [:id, :workflow_id, :intent, :reason, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent: Current.Intent.t(),
          reason: String.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
