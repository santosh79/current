defmodule Current.Event.ProposalProduced do
  use Current.Event.Versioned, version: 4

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

  # v3: Current.Proposal gained :observations. The proposal inside a v2
  # event was written without it.
  def upcast(fields, 2), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)

  # v4: Current.Proposal gained :revision and :revises.
  def upcast(fields, 3), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)
end
