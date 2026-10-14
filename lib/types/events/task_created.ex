defmodule Current.Event.TaskCreated do
  use Current.Event.Versioned, version: 3

  @enforce_keys [
    :id,
    :task_id,
    :input,
    :context,
    :mode,
    :project_dir,
    :model,
    :submitted_at,
    :timestamp
  ]

  defstruct [
    :id,
    :task_id,
    :input,
    :context,
    :mode,
    :submitted_at,
    :timestamp,
    :project_dir,
    :model,
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
          # The Current.ModelCatalog entry the task was submitted with
          # ("provider:model_id"), checked against the catalog at
          # submission (see Current.submit_task/3). Always present: a task
          # can't be submitted without one.
          model: String.t(),
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

  # v3 adds :model, which is required. A v2 task never recorded one and
  # none can be guessed, so a v2 event can't be read: start from a fresh
  # WAL rather than migrate one.
  def upcast(_fields, 2) do
    raise Current.Event.Schema.UpcastError, module: __MODULE__, from: 2, to: 3
  end
end
