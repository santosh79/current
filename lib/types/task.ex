defmodule Current.Task do
  @enforce_keys [:id, :input, :context, :submitted_at]
  defstruct [
    :id,
    :input,
    :context,
    :workflow_id,
    :submitted_at
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          workflow_id: Current.Id.t() | nil,
          submitted_at: DateTime.t()
        }

  @spec get(Current.Id.t()) ::
          {:ok, Current.Task.t()} | {:error, :not_found}
  def get(id), do: Current.TaskStore.get(id)
end
