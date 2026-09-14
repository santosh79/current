defmodule Current.Event.TaskCreated do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :task_id, :input, :context, :mode, :submitted_at, :timestamp]

  defstruct [
    :id,
    :task_id,
    :input,
    :context,
    :mode,
    :submitted_at,
    :timestamp,
    version: @schema_version
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t(),
          submitted_at: DateTime.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
