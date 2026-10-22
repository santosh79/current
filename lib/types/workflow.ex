defmodule Current.Workflow do
  @enforce_keys [:id, :task_id, :status, :created_at]
  defstruct [
    :id,
    :task_id,
    :status,
    :result,
    :events,
    :mode,
    :started_at,
    :created_at,
    :completed_at,
    :updated_at,
    :error,
    proposals: [],
    max_revisions: 10
  ]

  @type status ::
          :created
          | :planning
          | :validating
          | :waiting_for_approval
          | :validation_failed
          | :revision_requested
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
    :revision_requested,
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
          proposals: [Current.Proposal.t()],
          max_revisions: non_neg_integer(),
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

  @doc """
  The most recent proposal, or `nil` before the first one is produced.
  Every review decision must name this one.
  """
  @spec current_proposal(t()) :: Current.Proposal.t() | nil
  def current_proposal(%__MODULE__{proposals: proposals}), do: List.last(proposals)

  @doc "How many revisions have been requested and answered so far."
  @spec revisions_used(t()) :: non_neg_integer()
  def revisions_used(%__MODULE__{proposals: proposals}), do: max(length(proposals) - 1, 0)

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
end
