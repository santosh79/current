defmodule Current do
  alias Current.{
    Event,
    EventStore,
    Id,
    IntentPaths,
    ModelCatalog,
    ProposalStore,
    Request,
    TaskDispatcher,
    WorkflowReducer,
    WorkflowStore
  }

  @type decision ::
          {:approve, metadata :: map()}
          | {:reject, metadata :: map()}

  @doc """
  Submits a task for `project_dir` (default: the current working
  directory).

  The directory is resolved once, here, to its canonical physical path:
  absolute, every symlink followed, and required to exist as a directory.
  That is what TaskCreated records, so the recorded execution context
  means the same thing on replay whatever happens later to the node's
  working directory or to any symlink that was used to name it. (If the
  directory itself is later moved or removed, the workflow fails rather
  than following it.)

  `project_dir` is execution context, not request content, so it is an
  argument here rather than a `Request` field: this is its only entry
  point. It is recorded on TaskCreated, and WorkflowOrchestrator passes
  that recorded value to the proposal builder, IntentValidator and
  EffectApplicator.

  A `project_dir` that contains any `..` segment, isn't a directory, or
  can't be resolved (a symlink loop) is rejected before anything is
  registered or recorded.

  The request must name its model: `req.model` is one entry of
  `Current.ModelCatalog.all/0`, e.g. `"anthropic:claude-opus-5-5"`. It
  is checked against the catalog here, up front. One the catalog doesn't
  list is rejected with `{:error, {:unknown_model, model}}`, and a
  request without one with `{:error, :model_required}`, in both cases
  before anything is registered or recorded. An accepted model is
  recorded on TaskCreated; WorkflowOrchestrator picks the provider's
  client from it and the proposal builder asks that client for it.

  The catalog is filled asynchronously at startup (and by
  `Current.ModelCatalog.refresh/0`), so until a provider has answered,
  its models are unknown and are rejected here.
  """
  @spec submit_task(Request.t(), pid(), Path.t()) ::
          {:ok, Current.Id.t()}
          | {:error, :model_required}
          | {:error, {:unknown_model, ModelCatalog.model_name()}}
          | {:error,
             {:invalid_project_dir, Path.t(),
              :parent_segment | :not_a_directory | :too_many_links}}
          | {:error, term()}
  def submit_task(%Request{model: model} = req, caller_pid, project_dir \\ ".")
      when is_pid(caller_pid) and is_binary(project_dir) do
    with :ok <- validate_model(model),
         :ok <- validate_project_dir(project_dir),
         {:ok, canonical} <- canonical_project_dir(project_dir) do
      do_submit_task(req, caller_pid, canonical)
    end
  end

  defp validate_model(model) when is_binary(model) do
    if ModelCatalog.available?(model) do
      :ok
    else
      {:error, {:unknown_model, model}}
    end
  end

  defp validate_model(_no_model), do: {:error, :model_required}

  # realpath/1 keeps components that don't exist yet (right for a file
  # about to be written), so existence is checked separately.
  defp canonical_project_dir(project_dir) do
    case IntentPaths.realpath(Path.expand(project_dir)) do
      {:ok, canonical} ->
        if File.dir?(canonical),
          do: {:ok, canonical},
          else: {:error, {:invalid_project_dir, project_dir, :not_a_directory}}

      {:error, :too_many_links} ->
        {:error, {:invalid_project_dir, project_dir, :too_many_links}}
    end
  end

  defp validate_project_dir(project_dir) do
    if IntentPaths.parent_segment?(project_dir) do
      {:error, {:invalid_project_dir, project_dir, :parent_segment}}
    else
      :ok
    end
  end

  defp do_submit_task(req, caller_pid, project_dir) do
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
      project_dir: project_dir,
      model: req.model,
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

  @doc """
  Starts applying an approved proposal's effects.

  Approval only makes a proposal eligible to be applied; it never applies
  it. This is the separate, explicit step that does: it records
  EffectApplicationStarted, which the workflow's orchestrator reacts to
  by applying the effects. Only a workflow in `:approved` accepts it --
  applying a proposal that is still waiting for approval, was rejected,
  or is already applying/applied returns an invalid transition.

  Like `review_proposal/2`, the status check here is optimistic: the
  reducer checks the transition again at commit time, so of two
  concurrent applies only one becomes canonical.
  """
  @spec apply_proposal(Current.Id.t()) ::
          :ok
          | {:error, :not_found}
          | {:error, {:invalid_transition, Workflow.status(), module()}}
          | {:error, term()}
  def apply_proposal(proposal_id) do
    with {:ok, proposal} <- ProposalStore.get(proposal_id),
         {:ok, workflow} <- WorkflowStore.get(proposal.workflow_id),
         event = %Event.EffectApplicationStarted{
           id: Id.generate(),
           workflow_id: proposal.workflow_id,
           timestamp: DateTime.utc_now()
         },
         {:ok, _next} <- WorkflowReducer.apply_event(workflow, event) do
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
