defmodule Current.WorkflowReducer do
  @moduledoc """
  Pure derivation of workflow state from the event log.

  This module is the heart of Option B. Instead of mutating a `%Current.Workflow{}`
  imperatively inside the GenServer callbacks, every state transition is expressed
  as a pure function of the *current* state and the *next* event:

      apply_event(workflow_or_nil, event) :: workflow

  Folding the full, ordered event list through `apply_event/2` reconstructs the
  workflow from scratch — which is what makes the README's "state is derived from
  the event log" claim actually true. `replay/1` does exactly that fold.

  Design notes:

    * The very first event of any workflow is a `WorkflowCreated`. Its clause is
      the *genesis* clause: it takes `nil` and builds the initial struct. Every
      other clause takes an existing workflow and returns the next one.
    * Several events are **facts that do not change workflow status**
      (`EffectApplied`, `EffectsApplied`, `EffectFailed`, `ArtifactProduced`,
      `ArtifactsProduced`). They belong in the log for auditability/replay of the
      effect stream, but the reducer returns the workflow unchanged for them.
    * `updated_at` is advanced on every status-changing event; `started_at` is set
      once (when planning begins) and `completed_at` once (on a terminal event).
  """

  alias Current.Workflow
  alias Current.Event

  @doc """
  Apply a single event to the current workflow state, returning the next state.

  Called with `nil` for the genesis `WorkflowCreated` event; called with the
  current `%Workflow{}` for every subsequent event.
  """
  @spec apply_event(Workflow.t() | nil, Event.t()) :: Workflow.t()

  # --- Genesis -------------------------------------------------------------

  def apply_event(nil, %Event.WorkflowCreated{} = e) do
    %Workflow{
      id: e.workflow_id,
      task_id: e.task_id,
      status: :created,
      mode: e.mode,
      proposal: nil,
      result: nil,
      events: [],
      created_at: e.timestamp,
      updated_at: e.timestamp,
      started_at: nil,
      completed_at: nil,
      error: nil
    }
  end

  # --- Planning ------------------------------------------------------------

  def apply_event(%Workflow{} = w, %Event.ProposalProductionStarted{} = e) do
    %{w | status: :planning, started_at: w.started_at || e.timestamp, updated_at: e.timestamp}
  end

  def apply_event(%Workflow{} = w, %Event.ModeInvalid{} = e) do
    %{w | status: :invalid_mode, updated_at: e.timestamp}
  end

  def apply_event(%Workflow{} = w, %Event.ProposalProduced{} = e) do
    %{w | proposal: e.proposal, status: :validating, updated_at: e.timestamp}
  end

  # --- Validation ----------------------------------------------------------

  def apply_event(%Workflow{} = w, %Event.ProposalValidated{} = e) do
    %{w | status: :waiting_for_approval, updated_at: e.timestamp}
  end

  def apply_event(%Workflow{} = w, %Event.ProposalValidationFailed{} = e) do
    %{w | status: :validation_failed, error: error_reason(e.error), updated_at: e.timestamp}
  end

  # --- Approval ------------------------------------------------------------

  def apply_event(%Workflow{} = w, %Event.ProposalApproved{} = e) do
    %{w | status: :approved, updated_at: e.timestamp}
  end

  def apply_event(%Workflow{} = w, %Event.ProposalRejected{} = e) do
    %{w | status: :rejected, updated_at: e.timestamp}
  end

  # --- Effect application --------------------------------------------------

  def apply_event(%Workflow{} = w, %Event.EffectApplicationStarted{} = e) do
    %{w | status: :applying, updated_at: e.timestamp}
  end

  # Fact-only events: present in the log, but they do not move workflow status.
  def apply_event(%Workflow{} = w, %Event.EffectApplied{}), do: w
  def apply_event(%Workflow{} = w, %Event.EffectsApplied{}), do: w
  def apply_event(%Workflow{} = w, %Event.EffectFailed{}), do: w
  def apply_event(%Workflow{} = w, %Event.ArtifactProduced{}), do: w
  def apply_event(%Workflow{} = w, %Event.ArtifactsProduced{}), do: w

  # --- Result assembly -----------------------------------------------------

  def apply_event(%Workflow{} = w, %Event.WorkflowResultAssembled{} = e) do
    %{w | status: :assembling_result, result: e.result, updated_at: e.timestamp}
  end

  # --- Terminal states -----------------------------------------------------

  def apply_event(%Workflow{} = w, %Event.WorkflowCompleted{} = e) do
    %{w | status: :completed, completed_at: e.timestamp, updated_at: e.timestamp}
  end

  # def apply_event(%Workflow{} = w, %Event.WorkflowPlanned{} = e) do
  #   %{w | status: :planned, completed_at: e.timestamp, updated_at: e.timestamp}
  # end

  def apply_event(%Workflow{} = w, %Event.WorkflowFailed{} = e) do
    %{w | status: :failed, error: e.reason, updated_at: e.timestamp}
  end

  @doc """
  Rebuild a workflow by folding an ordered list of events from genesis.

  The first event must be a `WorkflowCreated` (the genesis event). Returns `nil`
  for an empty list.
  """
  @spec replay([Event.t()]) :: Workflow.t() | nil
  def replay(events) when is_list(events) do
    Enum.reduce(events, nil, fn event, acc -> apply_event(acc, event) end)
  end

  # An error may be a struct exposing `:reason`, or a bare term.
  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(other), do: other
end
