defmodule Current.Event.TaskCreated do
  @enforce_keys [:id, :task_id, :timestamp]
  defstruct [:id, :task_id, :mode, :timestamp]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          mode: Current.Mode.t(),
          timestamp: DateTime.t()
        }
end
