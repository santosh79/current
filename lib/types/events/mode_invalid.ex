defmodule Current.Event.ModeInvalid do
  @enforce_keys [:id, :workflow_id, :workflow, :mode, :timestamp]
  defstruct [:id, :workflow_id, :workflow, :mode, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          workflow: Current.Workflow.t(),
          mode: term(),
          timestamp: DateTime.t()
        }
end
