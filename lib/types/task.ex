defmodule Current.Task do
  @enforce_keys [:id, :input, :context, :mode, :model, :submitted_at]
  defstruct [:id, :input, :context, :mode, :submitted_at, :project_dir, :model]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t(),
          # nil for tasks recorded before project_dir existed.
          project_dir: Path.t() | nil,
          # The Current.ModelCatalog entry the task was submitted with.
          model: Current.ModelCatalog.model_name(),
          submitted_at: DateTime.t()
        }

  @spec get(Current.Id.t()) :: {:ok, Current.Task.t()} | {:error, :not_found}
  def get(id), do: Current.TaskStore.get(id)
end
