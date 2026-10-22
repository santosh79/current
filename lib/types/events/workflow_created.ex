defmodule Current.Event.WorkflowCreated do
  use Current.Event.Versioned, version: 2
  @enforce_keys [:id, :workflow_id, :timestamp]
  defstruct [
    :id,
    :workflow_id,
    :task_id,
    :mode,
    :timestamp,
    max_revisions: 10,
    version: @schema_version
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          task_id: Current.Id.t(),
          mode: Current.Mode.t(),
          # How many times a reviewer may send this workflow back for a
          # new proposal. Recorded here so replay never depends on config.
          max_revisions: non_neg_integer(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  # v2: added :max_revisions. Workflows created as v1 had no revisions, so
  # the bound is moot for them; 10 is the default the feature shipped with.
  def upcast(fields, 1), do: Map.put_new(fields, :max_revisions, 10)
end
