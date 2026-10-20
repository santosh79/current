defmodule Current.Task do
  @enforce_keys [:id, :input, :context, :mode, :model, :submitted_at]
  defstruct [:id, :input, :context, :mode, :submitted_at, :project_dir, :model, :timeout_ms]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t(),
          # nil for tasks recorded before project_dir existed.
          project_dir: Path.t() | nil,
          # The Current.ModelCatalog entry the task was submitted with.
          model: String.t(),
          # The bound, in ms, on producing its proposal; nil for the
          # runtime's default.
          timeout_ms: pos_integer() | nil,
          submitted_at: DateTime.t()
        }

  @spec get(Current.Id.t()) :: {:ok, Current.Task.t()} | {:error, :not_found}
  def get(id), do: Current.TaskStore.get(id)

  @doc """
  Every task, newest submission first. Each carries the user's `input`
  (the prompt), the `model` and the `timeout_ms` it was submitted with.
  """
  @spec all() :: [Current.Task.t()]
  def all, do: Current.TaskStore.all()

  @doc """
  The request details of a task -- prompt, model, timeout and project
  directory -- as a map. Every value is nil if the task isn't known.
  Used to enrich workflow and proposal listings.
  """
  @spec request_details(Current.Id.t() | nil) :: %{
          task_id: Current.Id.t() | nil,
          input: String.t() | map() | nil,
          model: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          project_dir: Path.t() | nil
        }
  def request_details(task_id) do
    case task_id && get(task_id) do
      {:ok, task} ->
        %{
          task_id: task.id,
          input: task.input,
          model: task.model,
          timeout_ms: task.timeout_ms,
          project_dir: task.project_dir
        }

      _ ->
        %{task_id: task_id, input: nil, model: nil, timeout_ms: nil, project_dir: nil}
    end
  end
end
