defmodule Current.Consensus.FailedEventsLog do
  use Agent

  @type state :: %{
          optional(Current.Id.t()) => Current.Event.t()
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(
      fn -> %{} end,
      name: __MODULE__
    )
  end

  @spec put(Current.Event.t()) :: :ok
  def put(%{id: event_id} = event) do
    Agent.update(
      __MODULE__,
      &Map.put(&1, event_id, event)
    )

    :ok
  end

  @spec get(Current.Id.t()) ::
          {:ok, Current.Event.t()} | {:error, :not_found}
  def get(event_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.fetch(state, event_id) do
        {:ok, event} ->
          {:ok, event}

        :error ->
          {:error, :not_found}
      end
    end)
  end

  @spec all() :: [Current.Event.t()]
  def all do
    Agent.get(
      __MODULE__,
      &Map.values/1
    )
  end
end
