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
      proposals: [],
      max_revisions: e.max_revisions,
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

  # A reviewer asked for a new proposal: production starts again, from
  # :revision_requested rather than :created. started_at keeps the first
  # start, so durations still measure the whole workflow.
  defp apply_event_helper(
         %Workflow{status: :revision_requested} = w,
         %Event.ProposalProductionStarted{} = e
       ) do
    {:ok,
     %{w | status: :planning, started_at: w.started_at || e.timestamp, updated_at: e.timestamp}}
  end

  defp apply_event_helper(%Workflow{status: :created} = w, %Event.ModeInvalid{} = e) do
    ww = %{w | status: :invalid_mode, updated_at: e.timestamp}
    {:ok, ww}
  end

  defp apply_event_helper(%Workflow{status: :planning} = w, %Event.ProposalProduced{} = e) do
    with :ok <- ensure_lineage(List.last(w.proposals), e.proposal) do
      {:ok,
       %{
         w
         | proposals: w.proposals ++ [e.proposal],
           status: :validating,
           updated_at: e.timestamp
       }}
    end
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

  # Only :apply workflows can be reviewed. A :plan workflow also passes
  # through :waiting_for_approval, between ProposalValidated and its
  # WorkflowCompleted, and a review landing in that window must not
  # commit: an approved plan workflow could then be applied.

  # Every decision must name the workflow's most recent proposal. This is
  # the one place that is enforced; callers just pass the error up.

  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval, mode: :apply} = w,
         %Event.ProposalApproved{} = e
       ) do
    with :ok <- ensure_current(w, e.proposal_id) do
      {:ok, %{w | status: :approved, updated_at: e.timestamp}}
    end
  end

  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval, mode: :apply} = w,
         %Event.ProposalRejected{} = e
       ) do
    with :ok <- ensure_current(w, e.proposal_id) do
      {:ok, %{w | status: :rejected, updated_at: e.timestamp}}
    end
  end

  # Revisions are bounded. The bound was recorded at genesis, so replaying
  # an old log never depends on today's config.
  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval, mode: :apply} = w,
         %Event.ProposalRevisionRequested{} = e
       ) do
    with :ok <- ensure_current(w, e.proposal_id),
         :ok <- ensure_revisions_left(w) do
      {:ok, %{w | status: :revision_requested, updated_at: e.timestamp}}
    end
  end

  defp apply_event_helper(
         %Workflow{status: :waiting_for_approval, mode: :plan} = w,
         %Event.WorkflowCompleted{} = e
       ) do
    ww = %{w | status: :planned, completed_at: e.timestamp, updated_at: e.timestamp}
    {:ok, ww}
  end

  # --- Effect application --------------------------------------------------

  # proposal_id is nil only on events recorded before workflows could hold
  # several proposals (EffectApplicationStarted v1); those replay as is.
  defp apply_event_helper(%Workflow{status: :approved} = w, %Event.EffectApplicationStarted{} = e) do
    with :ok <- ensure_current_or_legacy(w, e.proposal_id) do
      {:ok, %{w | status: :applying, updated_at: e.timestamp}}
    end
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

  defp ensure_current(%Workflow{} = w, proposal_id) do
    case Workflow.current_proposal(w) do
      %{id: ^proposal_id} -> :ok
      %{id: current_id} -> {:error, {:stale_proposal, proposal_id, current_id}}
      nil -> {:error, {:invalid_transition, w.status, :no_proposal}}
    end
  end

  defp ensure_current_or_legacy(_w, nil), do: :ok
  defp ensure_current_or_legacy(w, proposal_id), do: ensure_current(w, proposal_id)

  defp ensure_revisions_left(%Workflow{max_revisions: max} = w) do
    case Workflow.revisions_used(w) < max do
      true -> :ok
      false -> {:error, {:revision_limit_reached, max}}
    end
  end

  defp ensure_lineage(nil, %{revision: 0, revises: nil}), do: :ok

  defp ensure_lineage(nil, p) do
    {:error, {:invalid_proposal_lineage, %{new_revision: p.revision, new_revises: p.revises}}}
  end

  defp ensure_lineage(tail, p) do
    if p.id != tail.id and p.revises == tail.id and p.revision == tail.revision + 1 do
      :ok
    else
      {:error,
       {:invalid_proposal_lineage,
        %{
          tail_id: tail.id,
          tail_revision: tail.revision,
          new_id: p.id,
          new_revision: p.revision,
          new_revises: p.revises
        }}}
    end
  end

  defp ensure_lineage(_tail, other),
    do: {:error, {:invalid_proposal_lineage, {:not_a_proposal, other}}}

  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(other), do: other
end
