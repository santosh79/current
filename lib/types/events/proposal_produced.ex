defmodule Current.Event.ProposalProduced do
  use Current.Event.Versioned, version: 2

  @enforce_keys [:id, :workflow_id, :timestamp]
  defstruct [
    :id,
    :workflow_id,
    :proposal,
    :timestamp,
    :raw_output_blob_id,
    version: @schema_version
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          proposal: Current.Proposal.t(),
          raw_output_blob_id: Current.Id.t() | nil,
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  def upcast(fields, 1), do: fields
end
