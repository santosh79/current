defmodule Current.Event.ProposalProductionFailed do
  use Current.Event.Versioned, version: 2

  @enforce_keys [:id, :workflow_id, :error, :timestamp]
  defstruct [:id, :workflow_id, :error, :timestamp, version: @schema_version]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          error: Current.ProposalProductionError.t() | nil,
          timestamp: DateTime.t(),
          version: pos_integer()
        }

  # v1 carried a plain `reason: String.t()`. v2 replaces it with a
  # structured `error`, so this is a rename -- not additive -- and needs
  # an explicit migration: an identity upcast would leave old records
  # without the now-@enforce_keys'd :error field, which struct/2 rejects.
  # stage/raw_output_blob_id can't be recovered retroactively, so old
  # records get stage: nil (ProposalProductionError.message/1 has a
  # fallback clause for exactly this case).
  def upcast(%{reason: reason} = fields, 1) do
    fields
    |> Map.delete(:reason)
    |> Map.put(:error, %Current.ProposalProductionError{stage: nil, reason: reason})
  end
end
