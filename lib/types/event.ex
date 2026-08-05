defmodule Current.Event do
  @type t ::
          Current.Event.TaskCreated.t()
          | Current.Event.WorkflowCreated.t()
          | Current.Event.ProposalProductionStarted.t()
          | Current.Event.ModeInvalid.t()
          | Current.Event.ProposalProduced.t()
          | Current.Event.ProposalApproved.t()
          | Current.Event.ProposalValidated.t()
          | Current.Event.ProposalValidationFailed.t()
          | Current.Event.ProposalRejected.t()
          | Current.Event.EffectApplicationStarted.t()
          | Current.Event.EffectApplied.t()
          | Current.Event.EffectFailed.t()
          | Current.Event.EffectsApplied.t()
          | Current.Event.ArtifactProduced.t()
          | Current.Event.ArtifactsProduced.t()
          | Current.Event.WorkflowResultAssembled.t()
          | Current.Event.WorkflowCompleted.t()
          | Current.Event.WorkflowFailed.t()

  @known_modules [
    Current.Event.TaskCreated,
    Current.Event.WorkflowCreated,
    Current.Event.ProposalProductionStarted,
    Current.Event.ModeInvalid,
    Current.Event.ProposalProduced,
    Current.Event.ProposalValidated,
    Current.Event.ProposalValidationFailed,
    Current.Event.ProposalApproved,
    Current.Event.ProposalRejected,
    Current.Event.EffectApplicationStarted,
    Current.Event.EffectApplied,
    Current.Event.EffectFailed,
    Current.Event.EffectsApplied,
    Current.Event.ArtifactProduced,
    Current.Event.ArtifactsProduced,
    Current.Event.WorkflowResultAssembled,
    Current.Event.WorkflowCompleted,
    Current.Event.WorkflowFailed
  ]

  def valid?(%{__struct__: mod}), do: mod in @known_modules
  def valid?(_), do: false
end
