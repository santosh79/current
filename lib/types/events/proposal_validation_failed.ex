defmodule Current.Event.ProposalValidationFailed do
  use Current.Event.Versioned, version: 3

  @enforce_keys [:id, :workflow_id, :proposal, :error, :timestamp]
  defstruct [:id, :workflow_id, :proposal, :error, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          proposal: Current.Proposal.t(),
          error: Current.Error.ValidationError.t(),
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  # v2: Current.Proposal gained :observations. The proposal inside a v1
  # event was written without it.
  def upcast(fields, 1), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)

  # v3: Current.Proposal gained :revision and :revises.
  def upcast(fields, 2), do: Map.update(fields, :proposal, nil, &Current.Proposal.upcast/1)
end
