defmodule Current.Event.EffectApplied do
  @enforce_keys [:id, :workflow_id, :intent, :result, :timestamp]
  defstruct [:id, :workflow_id, :intent, :result, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent: Current.Intent.t(),
          result: Current.EffectApplicator.result(),
          timestamp: DateTime.t()
        }
end
