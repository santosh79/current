defmodule Current.WorkflowReducer do
  alias Current.{Error.ProposalProductionError, Workflow, Event}

  @doc """
  Apply a single event to the current workflow state, returning the next state.

  Called with `nil` for the genesis `WorkflowCreated` event; called with the
  current `%Workflow{}` for every subsequent event.
  """

  @spec apply_event(Workflow.t() | nil, Event.t()) ::
          {:ok, Workflow.t()}
          | {:error, {:workflow_id_mismatch, Current.Id.t(), Current.Id.t()}}
          | {:error, term()}

  # --- Genesis -------------------------------------------------------------
  def apply_event(nil, %Event.WorkflowCreated{} = e) do
    ww = %Workflow{
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

    {:ok, ww}
  end

  def apply_event(nil, event) do
    {:error, {:invalid_transition, nil, event.__struct__}}
  end

  def apply_event(
        %Workflow{id: workflow_id} = workflow,
        %{workflow_id: event_workflow_id} = event
      ) do
    case event_workflow_id == workflow_id do
      false -> {:error, {:workflow_id_mismatch, workflow_id, event_workflow_id}}
      true -> apply_event_helper(workflow, event)
    end
  end

  @spec replay([Event.t()]) :: {:ok, Workflow.t() | nil} | {:error, term()}
  def replay(events) when is_list(events) do
    Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, workflow} ->
      case apply_event(workflow, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- Planning ------------------------------------------------------------
  defp apply_event_helper(%Workflow{status: :created} = w, %Event.ProposalProductionStarted{} = e) do
    ww = %{
      w
      | status: :planning,
        started_at: w.started_at || e.timestamp,
        updated_at: e.timestamp
    }

    {:ok, ww}
  end

  defp apply_event_helper(%Workflow{status: :created} = w, %Event.ModeInvalid{} = e) do
    ww = %{w | status: :invalid_mode, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(%Workflow{status: :planning} = w, %Event.ProposalProduced{} = e) do
    ww = %{w | proposal: e.proposal, status: :validating, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(%Workflow{status: :planning} = w, %Event.ProposalProductionFailed{} = e) do
    {:ok,
     %{
       w
       | status: :proposal_production_failed,
         error: ProposalProductionError.message(e.error),
         updated_at: e.timestamp
     }}
  end

  # --- Validation ----------------------------------------------------------

  defp apply_event_helper(%Workflow{status: :validating} = w, %Event.ProposalValidated{} = e) do
    ww = %{w | status: :waiting_for_approval, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(
         %Workflow{status: :validating} = w,
         %Event.ProposalValidationFailed{} = e
       ) do
    ww = %{w | status: :validation_failed, error: error_reason(e.error), updated_at: e.timestamp}
    {:ok, ww}
  end

  # --- Approval ------------------------------------------------------------

  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval} = w,
         %Event.ProposalApproved{} = e
       ) do
    ww = %{w | status: :approved, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval} = w,
         %Event.ProposalRejected{} = e
       ) do
    ww = %{w | status: :rejected, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval, mode: :plan} = w,
         %Event.WorkflowCompleted{} = e
       ) do
    ww = %{w | status: :planned, completed_at: e.timestamp, updated_at: e.timestamp}
    {:ok, ww}
  end

  # --- Effect application --------------------------------------------------

  defp apply_event_helper(%Workflow{status: :approved} = w, %Event.EffectApplicationStarted{} = e) do
    ww = %{w | status: :applying, updated_at: e.timestamp}
    {:ok, ww}
  end

  # Fact-only events: present in the log, but they do not move workflow status.
  defp apply_event_helper(%Workflow{status: :applying} = w, %Event.EffectApplied{}), do: {:ok, w}

  defp apply_event_helper(%Workflow{status: :applying} = w, %Event.EffectApplicationComplete{}),
    do: {:ok, w}

  defp apply_event_helper(%Workflow{status: :applying} = w, %Event.EffectFailed{}), do: {:ok, w}

  # --- Result assembly -----------------------------------------------------

  defp apply_event_helper(%Workflow{status: :applying} = w, %Event.WorkflowResultAssembled{} = e) do
    ww = %{w | status: :assembling_result, result: e.result, updated_at: e.timestamp}
    {:ok, ww}
  end

  # --- Terminal states -----------------------------------------------------

  defp apply_event_helper(%Workflow{status: :applying} = w, %Event.WorkflowFailed{} = e) do
    ww = %{w | status: :failed, error: e.reason, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(%Workflow{status: :invalid_mode} = w, %Event.WorkflowFailed{} = e) do
    ww = %{w | status: :failed, error: e.reason, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(%Workflow{status: :validation_failed} = w, %Event.WorkflowFailed{} = e) do
    ww = %{w | status: :failed, error: e.reason, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(
         %Workflow{status: :proposal_production_failed} = w,
         %Event.WorkflowFailed{} = e
       ) do
    {:ok, %{w | status: :failed, error: e.reason, updated_at: e.timestamp}}
  end

  defp apply_event_helper(
         %Workflow{status: :assembling_result} = w,
         %Event.WorkflowCompleted{} = e
       ) do
    ww = %{w | status: :completed, completed_at: e.timestamp, updated_at: e.timestamp}
    {:ok, ww}
  end

  # WorkflowAbandoned is the runtime's own signal that no further automatic
  # progress is possible on this workflow -- distinct from WorkflowFailed
  # (a normal pipeline step concluding in failure). WorkflowRunner.give_up/2
  # proposes this after an orchestrator crash-loops past its retry budget,
  # which can happen from any point in a workflow's lifecycle, not only the
  # specific statuses WorkflowFailed's own transitions were designed around.
  defp apply_event_helper(%Workflow{} = w, %Event.WorkflowAbandoned{} = e) do
    case Workflow.terminal?(w) do
      true ->
        {:error, {:invalid_transition, w.status, Event.WorkflowAbandoned}}

      _ ->
        {:ok, %{w | status: :abandoned, error: e.reason, updated_at: e.timestamp}}
    end
  end

  defp apply_event_helper(workflow, event) do
    {:error, {:invalid_transition, workflow.status, event.__struct__}}
  end

  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(other), do: other
end
