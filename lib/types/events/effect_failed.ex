defmodule Current.Event.EffectFailed do
  @enforce_keys [:id, :workflow_id, :workflow, :intent, :reason, :timestamp]
  defstruct [:id, :workflow_id, :workflow, :intent, :reason, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          workflow: Current.Workflow.t(),
          intent: Current.Intent.t(),
          reason: String.t(),
          timestamp: DateTime.t()
        }
end
