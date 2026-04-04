defmodule Current.EventStore do
  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @spec append(Current.Event.t()) :: :ok | {:error, :invalid_event}
  def append(%Current.Event{} = event) do
    case Current.Event.valid_type?(event.type) do
      true ->
        Agent.update(__MODULE__, fn events -> [event | events] end)
        :ok
      _ -> {:error, :invalid_event}
    end
  end

  @spec list_by_workflow_id(Current.Id.t()) :: [Current.Event.t()]
  def list_by_workflow_id(workflow_id) do
    Agent.get(__MODULE__, fn events ->
      events
      |> Enum.reverse()
      |> Enum.filter(fn event -> event.workflow_id == workflow_id end)
    end)
  end
end
