defmodule Current.Event do
  @enforce_keys [:id, :workflow_id, :type, :data, :timestamp]
  defstruct [
    :id,
    :workflow_id,
    :type,
    :data,
    :timestamp
  ]

  @valid_types [
    :task_submitted,
    :workflow_created,
    :proposal_production_started,
    :proposal_produced,
    :approval_requested,
    :proposal_approved,
    :proposal_rejected,
    :intent_proposed,
    :intent_validated,
    :intent_rejected,
    :effect_application_started,
    :effect_applied,
    :effect_failed,
    :effects_applied,
    :artifact_produced,
    :claim_verified,
    :workflow_result_assembled,
    :workflow_completed,
    :workflow_failed,
  ]

  @type type :: unquote(Enum.reduce(@valid_types, &{:|, [], [&1, &2]}))

  @type t :: %__MODULE__{
    id: Current.Id.t(),
    workflow_id: Current.Id.t(),
    type: type(),
    data: map(),
    timestamp: DateTime.t()
  }

  def valid_type?(type), do: type in @valid_types
end

