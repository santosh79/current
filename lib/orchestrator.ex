defmodule Current.WorkflowOrchestrator do
  use GenServer

  alias Current.{
    EffectResult,
    Error,
    Event,
    EventStore,
    Id,
    IntentPaths,
    IntentValidator,
    Mode,
    Proposal,
    Error.ProposalProductionError,
    Request,
    Task,
    Workflow,
    WorkflowReducer
  }

  @type state :: %{
          listeners: [pid()],
          workflow_id: Current.Id.t(),
          request: Request.t(),
          project_dir: Path.t() | nil,
          task_id: Current.Id.t(),
          replayed: MapSet.t(Current.Id.t()),
          proposal_production: pid() | nil,
          # Where the proposal being produced sits in the workflow's chain.
          lineage: %{revision: non_neg_integer(), revises: Current.Id.t() | nil}
        }

  @type start_arg :: {Current.Id.t(), Task.t(), [pid()]}

  ## Client API

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({workflow_id, %Task{}, listeners} = arg)
      when is_binary(workflow_id) and is_list(listeners),
      do: GenServer.start_link(__MODULE__, arg)

  @doc """
  Like start_link/1, but does not link the caller. WorkflowRunner uses
  this (supervising via Process.monitor/1 instead) so an orchestrator
  crash arrives as a :DOWN message WorkflowRunner's own handle_info/2
  controls the response to, rather than an :EXIT signal propagating
  automatically and killing WorkflowRunner before its retry logic runs.
  """
  @spec start(start_arg()) :: GenServer.on_start()
  def start({workflow_id, %Task{}, listeners} = arg)
      when is_binary(workflow_id) and is_list(listeners),
      do: GenServer.start(__MODULE__, arg)

  @spec child_spec(start_arg()) :: Supervisor.child_spec()
  def child_spec({workflow_id, %Task{}, _listeners} = arg) do
    %{
      id: workflow_id,
      start: {__MODULE__, :start_link, [arg]},
      restart: :transient,
      type: :worker
    }
  end

  @impl true
  def init({workflow_id, %Task{} = task, listeners}) do
    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :all)

    state = %{
      listeners: listeners,
      task_id: task.id,
      request: %Request{
        input: task.input,
        context: task.context,
        mode: task.mode,
        # The model recorded on the task. start_proposal_production/1
        # picks the client from it.
        model: task.model,
        # The task's own bound on producing a proposal (nil: the default),
        # which the proposal builder reads off the request.
        timeout_ms: task.timeout_ms
      },
      # Execution context from the recorded task (nil for a legacy task).
      project_dir: task.project_dir,
      workflow_id: workflow_id,
      replayed: MapSet.new(),
      proposal_production: nil,
      lineage: %{revision: 0, revises: nil}
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    case EventStore.list_by_workflow_id(state.workflow_id) do
      [] ->
        # Genesis: nothing to replay yet. Already subscribed above, so
        # the commit notification for this proposal drives react/2
        # normally from here on -- no special-casing past this point.
        :ok =
          propose(%Event.WorkflowCreated{
            id: Id.generate(),
            workflow_id: state.workflow_id,
            task_id: state.task_id,
            mode: state.request.mode,
            # Read once, here, and recorded: the reducer enforces the
            # bound from the log, never from config.
            max_revisions: Application.get_env(:current, :max_revisions, 10),
            timestamp: DateTime.utc_now()
          })

        {:noreply, state}

      events ->
        {:ok, workflow} = WorkflowReducer.replay(events)
        state = %{state | replayed: MapSet.new(events, & &1.id)}
        recover(workflow, events, state)
    end
  end

  ## Committed workflow events
  @impl true
  def handle_info({:event_committed, %Current.EventStore.Entry{event: event}}, state) do
    if MapSet.member?(state.replayed, event.id) do
      {:noreply, state}
    else
      notify(state.listeners, event)
      react(event, state)
    end
  end

  ## Helper-process results

  ## Proposal builder results

  def handle_info({:proposal_produced, _}, %{proposal_production: nil} = state),
    do: {:noreply, state}

  # Paths are made absolute here, before the proposal becomes durable, so
  # everything downstream -- IntentValidator, the reviewer reading
  # ProposalStore, EffectApplicator (via Workflow.current_proposal/1), and any replay
  # -- sees exactly the same resolved paths. The model's untouched output
  # is still preserved in the raw_output_blob_id blob.
  def handle_info({:proposal_produced, %Proposal{} = proposal, raw_output_blob_id}, state) do
    propose(%Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      proposal: stamp_lineage(IntentPaths.absolutize(proposal, state.project_dir), state.lineage),
      raw_output_blob_id: raw_output_blob_id,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  def handle_info({:proposal_production_failed, _}, %{proposal_production: nil} = state),
    do: {:noreply, state}

  def handle_info({:proposal_production_failed, %ProposalProductionError{} = error}, state) do
    propose(%Event.ProposalProductionFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      error: error,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  def handle_info({:effect_applied, intent, result}, state) do
    propose(%Event.EffectApplied{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      intent: intent,
      result: result,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  def handle_info({:effect_application_complete, intent_results}, state) do
    propose(%Event.EffectApplicationComplete{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      intent_results: intent_results,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  def handle_info({:effect_failed, intent, reason}, state) do
    propose_effect_failed(state, intent, reason)
    {:noreply, state}
  end

  ## Recover policy

  defp recover(%Workflow{status: :applying}, events, state) do
    case List.last(events) do
      %Event.EffectApplicationStarted{} ->
        fail_interrupted_effects(state)

      # An unverified claim is recorded as EffectApplied first and then
      # fails the workflow; finish that if the crash fell in between.
      %Event.EffectApplied{intent: intent, result: %EffectResult.Claim{verified: false} = result} ->
        propose_effect_failed(state, intent, unverified_claim_reason(result))

      %Event.EffectApplied{} ->
        fail_interrupted_effects(state)

      %Event.EffectFailed{} = event ->
        react(event, state)

      # EffectApplicationComplete is the last thing durable before WorkflowResultAssembled.
      # Building the result is a pure, synchronous function of intent_results --
      # nothing external was left in flight, so this is just a normal react/2,
      # safe to redo even if it already happened once before the crash.
      %Event.EffectApplicationComplete{} = event ->
        react(event, state)
    end

    {:noreply, state}
  end

  defp recover(_workflow, events, state), do: react(List.last(events), state)

  ## Policy: committed event -> next operation

  defp react(%Event.WorkflowCreated{mode: mode}, state) do
    case Mode.valid?(mode) do
      true ->
        propose(%Event.ProposalProductionStarted{
          id: Id.generate(),
          workflow_id: state.workflow_id,
          timestamp: DateTime.utc_now()
        })

      false ->
        propose(%Event.ModeInvalid{
          id: Id.generate(),
          workflow_id: state.workflow_id,
          mode: mode,
          timestamp: DateTime.utc_now()
        })
    end

    {:noreply, state}
  end

  defp react(%Event.ProposalProductionStarted{}, state) do
    with_project_dir(state, "produce a proposal", fn ->
      {:noreply, start_proposal_production(state)}
    end)
  end

  defp react(%Event.ModeInvalid{mode: mode}, state) do
    propose(%Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      reason: "invalid mode: #{inspect(mode)}",
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp react(%Event.ProposalProduced{proposal: proposal}, state) do
    with_project_dir(state, "validate the proposal", fn ->
      event =
        case IntentValidator.validate(proposal, state.project_dir) do
          :ok ->
            %Event.ProposalValidated{
              id: Id.generate(),
              workflow_id: state.workflow_id,
              proposal: proposal,
              timestamp: DateTime.utc_now()
            }

          {:error, %Error.ValidationError{} = error} ->
            %Event.ProposalValidationFailed{
              id: Id.generate(),
              workflow_id: state.workflow_id,
              proposal: proposal,
              error: error,
              timestamp: DateTime.utc_now()
            }
        end

      propose(event)

      {:noreply, state}
    end)
  end

  defp react(
         %Event.ProposalValidated{},
         state
       ) do
    {:ok, workflow} =
      Current.WorkflowStore.get(state.workflow_id)

    case workflow.mode do
      :plan ->
        propose_completed(state)

      :apply ->
        :ok
    end

    {:noreply, state}
  end

  defp react(%Event.ProposalValidationFailed{}, state) do
    propose(%Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      reason: "proposal validation failed",
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp react(%Event.ProposalProductionFailed{error: error}, state) do
    propose(%Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      reason: ProposalProductionError.message(error),
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  # Approval makes a proposal eligible to be applied; it never applies it.
  # The workflow parks in :approved until Current.apply_proposal/1 records
  # EffectApplicationStarted. A task recorded before project_dir existed
  # could never be applied, so it is abandoned here rather than left
  # parked forever.
  defp react(%Event.ProposalApproved{}, state) do
    with_project_dir(state, "apply the proposal", fn -> {:noreply, state} end)
  end

  defp react(%Event.EffectApplicationStarted{}, state) do
    with_project_dir(state, "apply the proposal", fn ->
      start_effect_application(state)
      {:noreply, state}
    end)
  end

  defp react(%Event.EffectApplicationComplete{intent_results: intent_results}, state) do
    result = build_workflow_result(state.workflow_id, intent_results)

    propose(%Event.WorkflowResultAssembled{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      result: result,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp react(%Event.EffectFailed{reason: reason}, state) do
    propose(%Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      reason: reason,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp react(%Event.WorkflowResultAssembled{}, state) do
    propose_completed(state)
    {:noreply, state}
  end

  defp react(%Event.EffectApplied{}, state) do
    {:noreply, state}
  end

  defp react(%Event.ProposalRejected{}, state) do
    {:stop, :normal, state}
  end

  # The reducer has already moved the workflow to :revision_requested.
  # Production starts again from there; the feedback reaches the builder
  # via the workflow's events in start_proposal_production/1.
  defp react(%Event.ProposalRevisionRequested{}, state) do
    propose(%Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp react(%Event.WorkflowFailed{}, state) do
    {:stop, :normal, state}
  end

  defp react(%Event.WorkflowCompleted{}, state) do
    {:stop, :normal, state}
  end

  defp react(%Event.WorkflowAbandoned{}, state) do
    {:stop, :normal, state}
  end

  ## Proposal production

  defp start_proposal_production(state) do
    builder = Application.fetch_env!(:current, :proposal_builder)
    client = client_module(state.request)
    timeout_ms = Application.fetch_env!(:current, :llm_proposal_timeout_ms)

    orchestrator = self()
    project_dir = state.project_dir
    workflow_id = state.workflow_id
    {revision, lineage} = revision_context(workflow_id)
    request = %{state.request | revision: revision}

    pid =
      spawn_link(fn ->
        message =
          case client do
            {:ok, client_mod} ->
              case builder.build(request, workflow_id, client_mod, timeout_ms, project_dir) do
                {:ok, %Proposal{} = proposal} ->
                  raw_output_blob_id = nil
                  {:proposal_produced, proposal, raw_output_blob_id}

                {:ok, %Proposal{} = proposal, raw_output_blob_id} ->
                  {:proposal_produced, proposal, raw_output_blob_id}

                {:error, %ProposalProductionError{} = err} ->
                  {:proposal_production_failed, err}
              end

            {:error, reason} ->
              {:proposal_production_failed,
               %ProposalProductionError{
                 stage: :connection,
                 reason: reason
               }}
          end

        send(orchestrator, message)
      end)

    %{state | proposal_production: pid, lineage: lineage}
  end

  # What the builder needs to answer a revision request: every proposal so
  # far and every round of feedback, oldest first. Read from the log, the
  # same source recovery uses. Also the lineage to stamp on the result.
  defp revision_context(workflow_id) do
    events = EventStore.list_by_workflow_id(workflow_id)
    {:ok, workflow} = WorkflowReducer.replay(events)

    case workflow.proposals do
      [] ->
        {nil, %{revision: 0, revises: nil}}

      proposals ->
        feedback =
          for %Event.ProposalRevisionRequested{feedback: feedback} <- events, do: feedback

        {%{previous: proposals, feedback: feedback},
         %{revision: Workflow.revisions_used(workflow) + 1, revises: List.last(proposals).id}}
    end
  end

  # The orchestrator, not the model, decides where a proposal sits in the
  # chain, so the lineage cannot be forged by model output.
  defp stamp_lineage(%Proposal{} = proposal, %{revision: revision, revises: revises}),
    do: %{proposal | revision: revision, revises: revises}

  defp client_module(%Request{model: model}) do
    case client_for(model) do
      {:ok, client_mod} -> {:ok, client_mod}
      :error -> {:error, {:no_client_for_model, model}}
    end
  end

  ## Effect application

  defp start_effect_application(state) do
    orchestrator = self()
    {:ok, workflow} = Current.WorkflowStore.get(state.workflow_id)

    intents = Workflow.current_proposal(workflow).intents
    project_dir = state.project_dir

    spawn_link(fn ->
      try do
        case apply_intents_streaming(
               intents,
               orchestrator,
               project_dir,
               []
             ) do
          {:ok, intent_results} ->
            send(
              orchestrator,
              {:effect_application_complete, intent_results}
            )

          {:error, intent, reason} ->
            send(
              orchestrator,
              {:effect_failed, intent, reason}
            )
        end
      rescue
        e ->
          [first_intent | _] = intents

          send(
            orchestrator,
            {:effect_failed, first_intent, Exception.message(e)}
          )
      end
    end)

    :ok
  end

  defp apply_intents_streaming([], _orchestrator, _project_dir, acc) do
    {:ok, :lists.reverse(acc)}
  end

  defp apply_intents_streaming(
         [intent | rest],
         orchestrator,
         project_dir,
         acc
       ) do
    applicator = Application.fetch_env!(:current, :effect_applicator)

    case applicator.apply(intent, acc, project_dir) do
      # A claim that doesn't hold fails the workflow. Its result is still
      # recorded first, so the evidence that disproved it stays in the log.
      {:ok, %EffectResult.Claim{verified: false} = result} ->
        send(orchestrator, {:effect_applied, intent, result})
        {:error, intent, unverified_claim_reason(result)}

      {:ok, result} ->
        send(
          orchestrator,
          {:effect_applied, intent, result}
        )

        apply_intents_streaming(
          rest,
          orchestrator,
          project_dir,
          [{intent, result} | acc]
        )

      {:error, reason} ->
        {:error, intent, reason}
    end
  end

  ## Result

  defp build_workflow_result(workflow_id, intent_results) do
    %Current.WorkflowResult{
      id: Id.generate(),
      workflow_id: workflow_id,
      type: :result_bundle,
      intent_results: intent_results,
      summary: nil,
      metadata: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp propose_completed(state) do
    propose(%Event.WorkflowCompleted{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      timestamp: DateTime.utc_now()
    })
  end

  defp propose(event) do
    :ok = Current.Consensus.propose(event)
  end

  ## External notifications

  defp notify(listeners, event) do
    case notification(event) do
      nil ->
        :ok

      message ->
        Enum.each(listeners, &send(&1, message))
    end
  end

  defp notification(%Event.WorkflowCreated{} = event),
    do: {:workflow_created, event}

  defp notification(%Event.ProposalProductionStarted{} = event),
    do: {:proposal_production_started, event}

  defp notification(%Event.ModeInvalid{} = event),
    do: {:mode_invalid, event}

  defp notification(%Event.ProposalProduced{} = event),
    do: {:proposal_produced, event}

  defp notification(%Event.ProposalValidated{} = event),
    do: {:proposal_validated, event}

  defp notification(%Event.ProposalValidationFailed{} = event),
    do: {:proposal_validation_failed, event}

  defp notification(%Event.ProposalApproved{} = event),
    do: {:proposal_approved, event}

  defp notification(%Event.ProposalRejected{} = event),
    do: {:proposal_rejected, event}

  defp notification(%Event.ProposalRevisionRequested{} = event),
    do: {:proposal_revision_requested, event}

  defp notification(%Event.ProposalProductionFailed{} = event),
    do: {:proposal_production_failed, event}

  defp notification(%Event.EffectApplicationStarted{}),
    do: nil

  defp notification(%Event.EffectApplied{} = event),
    do: {:effect_applied, event}

  defp notification(%Event.EffectApplicationComplete{} = event),
    do: {:effect_application_complete, event}

  defp notification(%Event.EffectFailed{} = event),
    do: {:effect_failed, event}

  defp notification(%Event.WorkflowResultAssembled{} = event),
    do: {:workflow_result_assembled, event}

  defp notification(%Event.WorkflowCompleted{} = event),
    do: {:workflow_completed, event}

  defp notification(%Event.WorkflowFailed{} = event),
    do: {:workflow_failed, event}

  defp notification(%Event.WorkflowAbandoned{} = event),
    do: {:workflow_abandoned, event}

  ## Legacy tasks

  # A task recorded before project_dir existed (TaskCreated v1) has
  # project_dir: nil -- its project directory was never recorded and is
  # not guessed. The three steps that need one (producing, validating and
  # applying a proposal) check here first and abandon the workflow
  # explicitly instead. Nothing else does: replaying a legacy workflow,
  # projecting it, or reviewing a proposal still works as before.
  #
  # WorkflowAbandoned is the reducer's "no further automatic progress is
  # possible" transition, valid from every non-terminal status.
  defp with_project_dir(%{project_dir: nil} = state, step, _fun) do
    propose(%Event.WorkflowAbandoned{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      reason:
        "cannot #{step}: task #{state.task_id} was recorded before project_dir " <>
          "existed, so it has no project directory",
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp with_project_dir(_state, _step, fun), do: fun.()

  defp propose_effect_failed(state, intent, reason) do
    propose(%Event.EffectFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      intent: intent,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp unverified_claim_reason(%EffectResult.Claim{reason: reason}),
    do: "claim not verified: #{reason}"

  defp fail_interrupted_effects(state) do
    propose(%Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      reason:
        "effect application interrupted by runtime restart; " <>
          "one or more effects may have executed without a durable completion record",
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp client_for(model_name) when is_binary(model_name) do
    with {:ok, provider, _model_id} <- split(model_name),
         client when not is_nil(client) <-
           Enum.find(Current.ModelCatalog.llm_clients(), &(&1.provider() == provider)) do
      {:ok, client}
    else
      _ -> :error
    end
  end

  defp split(model_name) when is_binary(model_name) do
    case String.split(model_name, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {:ok, provider, model_id}

      _ ->
        :error
    end
  end
end
