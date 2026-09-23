defmodule Current.Event.TaskCreated do
  use Current.Event.Versioned, version: 2

  @enforce_keys [:id, :task_id, :input, :context, :mode, :project_dir, :submitted_at, :timestamp]

  defstruct [
    :id,
    :task_id,
    :input,
    :context,
    :mode,
    :submitted_at,
    :timestamp,
    :project_dir,
    version: @schema_version
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t(),
          # The canonical physical path of a directory that existed at
          # submission: absolute, symlinks resolved (see
          # Current.submit_task/3). nil only on events recorded before
          # project_dir existed (v1): those have no recorded directory.
          project_dir: Path.t() | nil,
          submitted_at: DateTime.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  # v2 adds :project_dir. A v1 event never recorded one, and nothing
  # recorded then can reconstruct it -- "." would mean whatever the node's
  # cwd happens to be at replay time, not what it was. So a v1 task gets
  # an explicit nil: "unknown", not a guess. WorkflowOrchestrator refuses
  # to produce, validate or apply anything for such a task.
  def upcast(fields, 1), do: Map.put(fields, :project_dir, nil)
end
