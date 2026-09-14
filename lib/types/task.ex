defmodule Current.Task do
  @enforce_keys [:id, :input, :context, :mode, :submitted_at]
  defstruct [:id, :input, :context, :mode, :submitted_at]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t(),
          submitted_at: DateTime.t()
        }

  @spec get(Current.Id.t()) :: {:ok, Current.Task.t()} | {:error, :not_found}
  def get(id), do: Current.TaskStore.get(id)
end
