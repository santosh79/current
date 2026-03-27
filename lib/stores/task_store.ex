defmodule Current.TaskStore do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(Current.Task.t()) :: :ok
  def put(task) do
    Agent.update(__MODULE__, &Map.put(&1, task.id, task))
    :ok
  end

  @spec get(Current.Id.t()) ::
          {:ok, Current.Task.t()} | {:error, :not_found}
  def get(id) do
    Agent.get(__MODULE__, fn state ->
      case Map.fetch(state, id) do
        {:ok, task} -> {:ok, task}
        :error -> {:error, :not_found}
      end
    end)
  end
end
