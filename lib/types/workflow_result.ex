defmodule Current.WorkflowResult do
  @enforce_keys [:id, :workflow_id, :type, :artifacts, :created_at]
  defstruct [
    :id,
    :workflow_id,
    :type,
    :artifacts,
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
          artifacts: [Current.Id.t()],
          summary: String.t() | nil,
          metadata: map() | nil,
          created_at: DateTime.t()
        }
end
