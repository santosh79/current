defmodule Current.Event do
  @type t ::
          Current.Event.TaskCreated.t()
          | Current.Event.WorkflowCreated.t()
          | Current.Event.ProposalProductionStarted.t()
          | Current.Event.ModeInvalid.t()
          | Current.Event.ProposalProduced.t()
          | Current.Event.ProposalProductionFailed.t()
          | Current.Event.ProposalApproved.t()
          | Current.Event.ProposalValidated.t()
          | Current.Event.ProposalValidationFailed.t()
          | Current.Event.ProposalRejected.t()
          | Current.Event.EffectApplicationStarted.t()
          | Current.Event.EffectApplied.t()
          | Current.Event.EffectFailed.t()
          | Current.Event.EffectApplicationComplete.t()
          | Current.Event.WorkflowResultAssembled.t()
          | Current.Event.WorkflowCompleted.t()
          | Current.Event.WorkflowFailed.t()
          | Current.Event.WorkflowAbandoned.t()

  @known_modules [
    Current.Event.TaskCreated,
    Current.Event.WorkflowCreated,
    Current.Event.ProposalProductionStarted,
    Current.Event.ModeInvalid,
    Current.Event.ProposalProduced,
    Current.Event.ProposalProductionFailed,
    Current.Event.ProposalValidated,
    Current.Event.ProposalValidationFailed,
    Current.Event.ProposalApproved,
    Current.Event.ProposalRejected,
    Current.Event.EffectApplicationStarted,
    Current.Event.EffectApplied,
    Current.Event.EffectFailed,
    Current.Event.EffectApplicationComplete,
    Current.Event.WorkflowResultAssembled,
    Current.Event.WorkflowCompleted,
    Current.Event.WorkflowFailed,
    Current.Event.WorkflowAbandoned
  ]

  @doc """
  Every committed event, newest first. TaskCreated events carry the
  user's prompt (`input`), `model` and `timeout_ms`.
  """
  @spec all() :: [t()]
  def all do
    {:ok, entries} = Current.EventStore.complete_log_entries()

    entries
    |> Enum.sort_by(& &1.position, :desc)
    |> Enum.map(& &1.event)
  end

  @spec modules() :: [module()]

  def modules,
    do: @known_modules

  @spec lifecycle_modules() :: [module()]

  def lifecycle_modules do
    @known_modules -- [Current.Event.TaskCreated]
  end

  def valid?(%{__struct__: mod}), do: mod in @known_modules
  def valid?(_), do: false
end
