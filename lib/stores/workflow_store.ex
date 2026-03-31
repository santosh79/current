defmodule Current.WorkflowStore do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(Current.Workflow.t()) :: :ok
  def put(workflow) do
    Agent.update(__MODULE__, &Map.put(&1, workflow.id, workflow))
    :ok
  end

  @spec get(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found}
  def get(id) do
    Agent.get(__MODULE__, fn state ->
      case Map.fetch(state, id) do
        {:ok, workflow} -> {:ok, workflow}
        :error -> {:error, :not_found}
      end
    end)
  end

  @spec get_by_task_id(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found}
  def get_by_task_id(task_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Map.values()
      |> Enum.find(fn workflow -> workflow.task_id == task_id end)
      |> case do
        nil -> {:error, :not_found}
        workflow -> {:ok, workflow}
      end
    end)
  end

  @spec get_status_by_task_id(Current.Id.t()) ::
          {:ok, Current.Workflow.status()} | {:error, :not_found}
  def get_status_by_task_id(task_id) do
    case get_by_task_id(task_id) do
      {:ok, workflow} -> {:ok, workflow.status}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec get_by_proposal_id(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found}
  def get_by_proposal_id(proposal_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Map.values()
      |> Enum.find(fn workflow ->
        match?(%Current.Proposal{id: ^proposal_id}, workflow.proposal)
      end)
      |> case do
        nil -> {:error, :not_found}
        workflow -> {:ok, workflow}
      end
    end)
  end
end
