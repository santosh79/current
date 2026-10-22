defmodule Current.Event.ProposalRevisionRequested do
  use Current.Event.Versioned, version: 1

  @enforce_keys [:id, :workflow_id, :proposal_id, :feedback, :metadata, :timestamp]

  defstruct [
    :id,
    :workflow_id,
    :proposal_id,
    :feedback,
    :metadata,
    :timestamp,
    version: @schema_version
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          # The proposal the reviewer saw. Must be the workflow's latest.
          proposal_id: Current.Id.t(),
          feedback: String.t(),
          metadata: map(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }
end
