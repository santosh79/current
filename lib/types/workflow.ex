defmodule Current.Workflow do
  @enforce_keys [:id, :task_id, :status, :created_at]
  defstruct [
    :id,
    :task_id,
    :status,
    :proposal,
    :result,
    :events,
    :mode,
    :started_at,
    :created_at,
    :completed_at,
    :updated_at,
    :error
  ]

  @type status ::
          :created
          | :planning
          | :validating
          | :waiting_for_approval
          | :validation_failed
          | :approved
          | :applying
          | :assembling_result
          | :completed
          | :planned
          | :invalid_mode
          | :rejected
          | :failed
          | :proposal_production_failed
          | :abandoned

  @statuses [
    :created,
    :planning,
    :validating,
    :waiting_for_approval,
    :validation_failed,
    :approved,
    :applying,
    :assembling_result,
    :completed,
    :planned,
    :invalid_mode,
    :rejected,
    :failed,
    :proposal_production_failed,
    :abandoned
  ]

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          status: status(),
          proposal: Current.Proposal.t() | nil,
          result: Current.WorkflowResult.t() | nil,
          events: [Current.Event.t()],
          mode: Current.Mode.t(),
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          error: String.t() | nil
        }
  @terminal_statuses [:completed, :planned, :rejected, :failed, :abandoned]

  @doc """
  Every workflow, newest first, each as a map holding the `:workflow`
  together with the `:input` (the user's prompt), `:model`, `:timeout_ms`,
  `:project_dir` and `:task_id` of the task it belongs to.
  """
  @spec all() :: [map()]
  def all do
    Current.WorkflowStore.all()
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.map(fn workflow ->
      Map.put(Current.Task.request_details(workflow.task_id), :workflow, workflow)
    end)
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
end
