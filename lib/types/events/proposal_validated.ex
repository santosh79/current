defmodule Current.Event.ProposalValidated do
  use Current.Event.Versioned, version: 2
  @enforce_keys [:id, :workflow_id, :proposal, :timestamp]
  defstruct [:id, :workflow_id, :proposal, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          proposal: Current.Proposal.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  # v2: Current.Proposal gained :observations. The proposal inside a v1
  # event was written without it.
  def upcast(fields, 1), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)
end
