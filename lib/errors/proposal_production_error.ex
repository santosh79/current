defmodule Current.ProposalProductionError do
  @enforce_keys [:stage, :reason]
  defstruct [:stage, :reason, :raw_output_blob_id]

  @type stage :: :connection | :timeout | :decode | nil

  @type t :: %__MODULE__{
          stage: stage(),
          reason: term(),
          raw_output_blob_id: Current.Id.t() | nil
        }

  @doc """
  Renders a human-readable summary of this error. This is the one place
  that turns a structured cause into a display string, so callers never
  need to duplicate that logic (WorkflowReducer needs it for Workflow.error,
  WorkflowOrchestrator needs it for Event.WorkflowFailed.reason).
  """
  @spec message(t() | nil) :: String.t()
  def message(nil), do: "proposal production failed"

  def message(%__MODULE__{stage: :connection, reason: reason}),
    do: "could not connect to the model: #{inspect(reason)}"

  def message(%__MODULE__{stage: :timeout, reason: reason}),
    do: "proposal production timed out: #{inspect(reason)}"

  def message(%__MODULE__{stage: :decode, reason: reason}),
    do: "model response could not be decoded: #{inspect(reason)}"

  def message(%__MODULE__{stage: nil, reason: reason}),
    do: "proposal production failed: #{inspect(reason)}"
end
