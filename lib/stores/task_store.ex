defmodule Current.TaskStore do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(Current.Request.t()) :: {:ok, Current.Id.t()}
  def put(req) do
    task_id = Current.Id.generate()

    now = DateTime.utc_now()

    task = %Current.Task{
      id: task_id,
      input: req.input,
      context: req.context,
      submitted_at: now
    }

    Agent.update(__MODULE__, &Map.put(&1, task_id, task))
    {:ok, task_id}
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
