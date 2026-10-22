defmodule Current.Event.EffectApplicationStarted do
  use Current.Event.Versioned, version: 2

  @enforce_keys [:id, :workflow_id, :timestamp]
  defstruct [:id, :workflow_id, :timestamp, :proposal_id, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          # The proposal being applied. nil only on events recorded as v1,
          # before a workflow could hold more than one proposal.
          proposal_id: Current.Id.t() | nil,
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  # v2: added :proposal_id. v1 events never named the proposal.
  def upcast(fields, 1), do: Map.put_new(fields, :proposal_id, nil)
end
