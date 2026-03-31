defmodule Current.RuntimeRegistry do
  use Agent

  @type runtime_entry :: %{
          workflow_pid: pid(),
          orchestrator_pid: pid()
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(Current.Id.t(), runtime_entry()) :: :ok
  def put(workflow_id, entry) when is_binary(workflow_id) and is_map(entry) do
    Agent.update(__MODULE__, &Map.put(&1, workflow_id, entry))
    :ok
  end

  @spec get(Current.Id.t()) :: {:ok, runtime_entry()} | {:error, :not_found}
  def get(workflow_id) when is_binary(workflow_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.fetch(state, workflow_id) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, :not_found}
      end
    end)
  end

  @spec delete(Current.Id.t()) :: :ok
  def delete(workflow_id) when is_binary(workflow_id) do
    Agent.update(__MODULE__, &Map.delete(&1, workflow_id))
    :ok
  end
end
