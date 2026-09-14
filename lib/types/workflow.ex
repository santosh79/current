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
    :failed
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
  @terminal_statuses [:completed, :planned, :rejected, :failed]

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
end
