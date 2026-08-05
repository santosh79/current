defmodule Current.EventStore do
  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @spec append(Current.Event.t()) :: :ok | {:error, :invalid_event}
  def append(event) do
    if Current.Event.valid?(event) do
      Agent.update(__MODULE__, fn events -> [event | events] end)
      :ok
    else
      {:error, :invalid_event}
    end
  end

  @doc """
  All events for a workflow stream, oldest first.

  Not every event carries a `workflow_id` — `TaskCreated` is a task-level fact —
  so the filter uses `Map.get/2` rather than struct dot-access (which raises
  `KeyError` for structs without the field and would crash the Agent).
  """
  @spec list_by_workflow_id(Current.Id.t()) :: [Current.Event.t()]
  def list_by_workflow_id(workflow_id) do
    Agent.get(__MODULE__, fn events ->
      events
      |> Enum.reverse()
      |> Enum.filter(fn event -> Map.get(event, :workflow_id) == workflow_id end)
    end)
  end
end
