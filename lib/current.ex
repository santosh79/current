defmodule Current do
  alias Current.{
    Event,
    EventStore,
    Id,
    ProposalStore,
    Request,
    TaskDispatcher,
    WorkflowReducer,
    WorkflowStore
  }

  @type decision ::
          {:approve, metadata :: map()}
          | {:reject, metadata :: map()}

  @spec submit_task(Request.t(), pid()) ::
          {:ok, Current.Id.t()}
  def submit_task(%Request{} = req, caller_pid)
      when is_pid(caller_pid) do
    task_id = Id.generate()
    now = DateTime.utc_now()

    :ok =
      TaskDispatcher.register_listener(
        task_id,
        caller_pid
      )

    event = %Event.TaskCreated{
      id: Id.generate(),
      task_id: task_id,
      input: req.input,
      context: req.context,
      mode: req.mode,
      submitted_at: now,
      timestamp: now
    }

    case Current.Consensus.propose(event) do
      :ok ->
        {:ok, task_id}

      error ->
        error
    end
  end

  @spec get_workflow(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found}
  def get_workflow(task_id) do
    WorkflowStore.get_by_task_id(task_id)
  end

  @spec get_status(Current.Id.t()) ::
          {:ok, Current.Workflow.status()} | {:error, :not_found}
  def get_status(task_id) do
    WorkflowStore.get_status_by_task_id(task_id)
  end

  @spec replay_workflow(Current.Id.t()) ::
          {:ok, Current.Workflow.t()} | {:error, :not_found} | {:error, term()}
  def replay_workflow(workflow_id) do
    case EventStore.list_by_workflow_id(workflow_id) do
      [] ->
        {:error, :not_found}

      events ->
        WorkflowReducer.replay(events)
    end
  end

  @spec review_proposal(Current.Id.t(), decision()) ::
          :ok
          | {:error, :not_found}
          | {:error, {:invalid_transition, Workflow.status(), module()}}
          | {:error, term()}
  def review_proposal(proposal_id, decision) do
    with {:ok, proposal} <- ProposalStore.get(proposal_id),
         {:ok, workflow} <- WorkflowStore.get(proposal.workflow_id),
         event = decision_event(proposal, decision),
         {:ok, _next} <- WorkflowReducer.apply_event(workflow, event) do
      # Optimistic check only: the projection is current as of
      # WorkflowStore.sync/0, but another review can still land between
      # here and commit. The reducer runs again at commit time, so a
      # loser in that race is rejected there and recorded in
      # FailedEventsLog -- this pre-check just stops the common,
      # non-racy cases (already reviewed, plan-mode, terminal) from
      # returning :ok for an event that will never become canonical.
      Current.Consensus.propose(event)
    end
  end

  defp decision_event(proposal, {:approve, metadata}) do
    %Event.ProposalApproved{
      id: Id.generate(),
      workflow_id: proposal.workflow_id,
      proposal_id: proposal.id,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }
  end

  defp decision_event(proposal, {:reject, metadata}) do
    %Event.ProposalRejected{
      id: Id.generate(),
      workflow_id: proposal.workflow_id,
      proposal_id: proposal.id,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }
  end
end
