defmodule Current.Error.ProposalProductionError do
  @enforce_keys [:stage, :reason]
  defstruct [:stage, :reason, :raw_output_blob_id]

  # Every stage but :internal is an expected failure at a boundary (the
  # project directory, the model, its reply). :internal is a bug in the
  # builder itself.
  @type stage ::
          :project_context | :connection | :timeout | :decode | :context_budget | :internal | nil

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

  def message(%__MODULE__{stage: :project_context, reason: reason}),
    do: "could not read the project directory: #{inspect(reason)}"

  def message(%__MODULE__{stage: :connection, reason: {:truncated, reason, count}})
      when reason in [:max_tokens, :length],
      do:
        "model response was truncated at #{count} output tokens; increase the provider's output limit"

  def message(%__MODULE__{stage: :connection, reason: {:invalid_local_llm_setting, setting}}),
    do: "invalid self-hosted model setting CURRENT_LOCAL_LLM_#{setting}"

  def message(%__MODULE__{stage: :connection, reason: reason}),
    do: "could not connect to the model: #{inspect(reason)}"

  def message(%__MODULE__{stage: :timeout, reason: reason}),
    do: "proposal production timed out: #{inspect(reason)}"

  def message(%__MODULE__{stage: :decode, reason: reason}),
    do: "model response could not be decoded: #{inspect(reason)}"

  def message(%__MODULE__{stage: :context_budget, reason: reason}),
    do: "the model did not produce a proposal: #{inspect(reason)}"

  def message(%__MODULE__{stage: :internal, reason: reason}),
    do: "the proposal builder failed unexpectedly: #{reason}"

  def message(%__MODULE__{stage: nil, reason: reason}),
    do: "proposal production failed: #{inspect(reason)}"
end
