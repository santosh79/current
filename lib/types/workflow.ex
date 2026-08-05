defmodule Current.Workflow do
  use GenServer

  alias Current.{
    ArtifactBuilder,
    Event,
    EventStore,
    Id,
    Proposal,
    Request,
    TaskStore,
    Task,
    WorkflowReducer,
    WorkflowStore
  }

  @enforce_keys [:id, :task_id, :status, :created_at]
  defstruct [
    :id,
    :task_id,
    :status,
    :proposal,
    :result,
    :events,
    :mode,
    :started_at,
    :created_at,
    :completed_at,
    :updated_at,
    :error
  ]

  @type status ::
          :created
          | :planning
          | :validating
          | :waiting_for_approval
          | :validation_failed
          | :approved
          | :applying
          | :assembling_result
          | :completed
          | :planned
          | :invalid_mode
          | :rejected
          | :failed

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          status: status(),
          proposal: Current.Proposal.t() | nil,
          result: Current.WorkflowResult.t() | nil,
          events: [Current.Event.t()],
          mode: Current.Mode.t(),
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          error: String.t() | nil
        }

  @type state :: %{
          workflow: t(),
          request: Request.t(),
          orchestrator_pid: pid()
        }

  @typedoc """
  Commands the orchestrator (process manager) may cast at the aggregate. Each
  accepted command results in one or more events being emitted.
  """
  @type workflow_command ::
          :start_planning
          | :mark_mode_invalid
          | :mark_proposal_validated
          | {:mark_proposal_validation_failed, Current.Error.ValidationError.t()}
          | {:record_proposal_decision, Current.Id.t(), Current.decision()}
          | :apply_effects
          | {:produce_artifacts, [{Current.Intent.t(), Current.EffectApplicator.result()}]}
          | {:assemble_result, [Current.Artifact.t()]}
          | :complete_as_plan
          | :complete
          | {:fail, String.t()}

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec create(Current.Id.t(), Request.t(), pid()) ::
          {:ok, pid(), Current.Id.t()} | {:error, term()}
  def create(task_id, %Request{} = req, orchestrator_pid)
      when is_pid(orchestrator_pid) do
    workflow_id = Id.generate()

    {:ok, pid} =
      start_link(
        task_id: task_id,
        workflow_id: workflow_id,
        request: req,
        orchestrator_pid: orchestrator_pid
      )

    {:ok, pid, workflow_id}
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    req = Keyword.fetch!(opts, :request)
    orchestrator_pid = Keyword.fetch!(opts, :orchestrator_pid)
    now = DateTime.utc_now()

    task = %Task{
      id: task_id,
      input: req.input,
      context: req.context,
      workflow_id: workflow_id,
      submitted_at: now
    }

    :ok = TaskStore.put(task)

    genesis = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: task_id,
      mode: req.mode,
      timestamp: now
    }

    workflow = WorkflowReducer.apply_event(nil, genesis)

    :ok = EventStore.append(genesis)
    :ok = WorkflowStore.put(workflow)
    send(orchestrator_pid, {:workflow_event, genesis})

    state = %{
      workflow: workflow,
      request: req,
      orchestrator_pid: orchestrator_pid
    }

    {:ok, state}
  end

  ## Commands (from the orchestrator)

  @impl true
  def handle_cast(:start_planning, state) do
    w = state.workflow

    event = %Event.ProposalProductionStarted{
      id: Id.generate(),
      workflow_id: w.id,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)

    :ok = start_proposal_production(state)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast(:mark_mode_invalid, state) do
    w = state.workflow

    event = %Event.ModeInvalid{
      id: Id.generate(),
      workflow_id: w.id,
      mode: w.mode,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast(:mark_proposal_validated, state) do
    w = state.workflow

    event = %Event.ProposalValidated{
      id: Id.generate(),
      workflow_id: w.id,
      proposal: w.proposal,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast(
        {:mark_proposal_validation_failed, %Current.Error.ValidationError{} = error},
        state
      ) do
    w = state.workflow

    event =
      %Event.ProposalValidationFailed{
        id: Id.generate(),
        workflow_id: w.id,
        proposal: w.proposal,
        error: error,
        timestamp: DateTime.utc_now()
      }

    updated_state = emit(state, event)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:record_proposal_decision, proposal_id, decision}, state) do
    w = state.workflow

    case {state.workflow.status, state.workflow.proposal, decision} do
      {:waiting_for_approval, %Proposal{id: ^proposal_id}, {:approve, _metadata}} ->
        event = %Event.ProposalApproved{
          id: Id.generate(),
          workflow_id: w.id,
          timestamp: DateTime.utc_now()
        }

        updated_state = emit(state, event)
        {:noreply, updated_state}

      {:waiting_for_approval, %Proposal{id: ^proposal_id}, {:reject, _metadata}} ->
        event = %Event.ProposalRejected{
          id: Id.generate(),
          workflow_id: w.id,
          timestamp: DateTime.utc_now()
        }

        updated_state = emit(state, event)
        {:noreply, updated_state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:apply_effects, state) do
    w = state.workflow

    event = %Event.EffectApplicationStarted{
      id: Id.generate(),
      workflow_id: w.id,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)
    :ok = start_effect_application(state)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:produce_artifacts, intent_results}, state) do
    new_state = gen_artifacts(intent_results, state, [])
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:assemble_result, artifacts}, state) do
    result = build_workflow_result(state.workflow, artifacts)
    w = state.workflow

    event = %Event.WorkflowResultAssembled{
      id: Id.generate(),
      workflow_id: w.id,
      result: result,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)

    {:noreply, updated_state}
  end

  @impl true
  def handle_cast(:complete_as_plan, state) do
    # The reducer derives :planned from (mode: :plan, WorkflowCompleted).
    {:noreply, emit_completed(state)}
  end

  @impl true
  def handle_cast(:complete, state) do
    {:noreply, emit_completed(state)}
  end

  @impl true
  def handle_cast({:fail, reason}, state) do
    w = state.workflow

    event = %Event.WorkflowFailed{
      id: Id.generate(),
      workflow_id: w.id,
      reason: reason,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)

    {:noreply, updated_state}
  end

  ## Facts reported by helper processes

  @impl true
  def handle_info({:proposal_produced, %Proposal{} = proposal}, state) do
    w = state.workflow

    event = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: w.id,
      proposal: proposal,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:effect_applied, intent, result}, state) do
    w = state.workflow

    event = %Event.EffectApplied{
      id: Id.generate(),
      workflow_id: w.id,
      intent: intent,
      result: result,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:effects_applied, intent_results}, state) do
    w = state.workflow

    event = %Event.EffectsApplied{
      id: Id.generate(),
      workflow_id: w.id,
      intent_results: intent_results,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:effect_failed, intent, reason}, state) do
    w = state.workflow

    event = %Event.EffectFailed{
      id: Id.generate(),
      workflow_id: w.id,
      intent: intent,
      reason: reason,
      timestamp: DateTime.utc_now()
    }

    updated_state = emit(state, event)
    {:noreply, updated_state}
  end

  ## Event-sourced transition pipeline

  defp emit(%{workflow: workflow, orchestrator_pid: orchestrator_pid} = state, event) do
    updated_workflow = WorkflowReducer.apply_event(workflow, event)

    :ok = EventStore.append(event)
    :ok = WorkflowStore.put(updated_workflow)
    send(orchestrator_pid, {:workflow_event, event})
    %{state | workflow: updated_workflow}
  end

  defp emit_completed(state) do
    w = state.workflow

    event = %Event.WorkflowCompleted{
      id: Id.generate(),
      workflow_id: w.id,
      timestamp: DateTime.utc_now()
    }

    emit(state, event)
  end

  ## Helper processes (side effects)

  defp start_proposal_production(%{request: req, workflow: workflow}) do
    builder = :persistent_term.get(:proposal_builder, Current.ProposalBuilder)
    workflow_pid = self()

    spawn_link(fn ->
      {:ok, proposal} = builder.build(req, workflow.id)
      send(workflow_pid, {:proposal_produced, proposal})
    end)

    :ok
  end

  defp start_effect_application(%{workflow: workflow}) do
    workflow_pid = self()
    intents = workflow.proposal.intents

    spawn_link(fn ->
      try do
        case apply_intents_streaming(intents, workflow_pid, []) do
          {:ok, intent_results} ->
            send(workflow_pid, {:effects_applied, intent_results})

          {:error, intent, reason} ->
            send(workflow_pid, {:effect_failed, intent, reason})
        end
      rescue
        e ->
          [first_intent | _] = intents
          send(workflow_pid, {:effect_failed, first_intent, Exception.message(e)})
      end
    end)

    :ok
  end

  defp apply_intents_streaming([], _workflow_pid, acc) do
    {:ok, :lists.reverse(acc)}
  end

  defp apply_intents_streaming([intent | rest], workflow_pid, acc) do
    applicator = :persistent_term.get(:effect_applicator, Current.EffectApplicator)

    case applicator.apply(intent, acc) do
      {:ok, result} ->
        send(workflow_pid, {:effect_applied, intent, result})
        apply_intents_streaming(rest, workflow_pid, [{intent, result} | acc])

      {:error, reason} ->
        {:error, intent, reason}
    end
  end

  # SantoshTODO: Stop Hardcoding
  defp build_workflow_result(workflow, artifacts) do
    %Current.WorkflowResult{
      id: Id.generate(),
      workflow_id: workflow.id,
      type: :result_bundle,
      artifacts: Enum.map(artifacts, & &1.id),
      summary: nil,
      metadata: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp gen_artifacts([], state, acc) do
    artifacts = acc |> :lists.reverse()
    w = state.workflow

    event = %Event.ArtifactsProduced{
      id: Id.generate(),
      workflow_id: w.id,
      artifacts: artifacts,
      timestamp: DateTime.utc_now()
    }

    new_state = emit(state, event)
    new_state
  end

  defp gen_artifacts([intent_result | rest], state, acc) do
    {intent, result} = intent_result
    {:ok, artifact} = ArtifactBuilder.build(state.workflow, intent_result)
    w = state.workflow

    event = %Event.ArtifactProduced{
      id: Id.generate(),
      workflow_id: w.id,
      intent: intent,
      result: result,
      artifact: artifact,
      timestamp: DateTime.utc_now()
    }

    new_state = emit(state, event)
    gen_artifacts(rest, new_state, [artifact | acc])
  end
end
