defmodule Current.WorkflowResult do
  @enforce_keys [:id, :workflow_id, :type, :intent_results, :created_at]
  defstruct [
    :id,
    :workflow_id,
    :type,
    :intent_results,
    :summary,
    :metadata,
    :created_at
  ]

  @type type ::
          :result_bundle
          | :report
          | :manifest
          | :patch_set
          | :verification_output

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          type: type(),
          intent_results: [{Current.Intent.t(), Current.EffectApplicator.result()}],
          summary: String.t() | nil,
          metadata: map() | nil,
          created_at: DateTime.t()
        }
end
