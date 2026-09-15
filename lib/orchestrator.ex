defmodule Current.WorkflowOrchestrator do
  use GenServer

  alias Current.{
    Error,
    Event,
    EventStore,
    Id,
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
          task_id: Current.Id.t(),
          replayed: MapSet.t(Current.Id.t()),
          proposal_production: %{pid: pid(), timer: reference()} | nil
        }

  @type start_arg ::
          {Event.TaskCreated.t(), [pid()]}
          | {:resume, Workflow.t(), Task.t()}

  ## Client API

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({%Event.TaskCreated{}, listeners} = arg) when is_list(listeners),
    do: GenServer.start_link(__MODULE__, arg)

  def start_link({:resume, %Workflow{}, %Task{}} = arg),
    do: GenServer.start_link(__MODULE__, arg)

  @spec child_spec(start_arg()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({%Event.TaskCreated{} = event, listeners}) do
    request = %Request{
      input: event.input,
      context: event.context,
      mode: event.mode
    }

    workflow_id = Id.generate()

    :ok =
      Current.EventNotifier.subscribe(
        self(),
        workflow_id,
        :all
      )

    workflow_created = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: event.task_id,
      mode: event.mode,
      timestamp: DateTime.utc_now()
    }

    :ok = propose(workflow_created)

    {:ok,
     %{
       listeners: listeners,
       task_id: event.task_id,
       request: request,
       workflow_id: workflow_id,
       replayed: MapSet.new(),
       proposal_production: nil
     }}
  end

  def init({:resume, %Workflow{} = workflow, %Task{} = task}) do
    :ok = Current.EventNotifier.subscribe(self(), workflow.id, :all)

    state = %{
      listeners: [],
      task_id: task.id,
      request: %Request{input: task.input, context: task.context, mode: task.mode},
      workflow_id: workflow.id,
      replayed: MapSet.new(),
      proposal_production: nil
    }

    {:ok, state, {:continue, :resume}}
  end

  @impl true
  def handle_continue(:resume, state) do
    events = EventStore.list_by_workflow_id(state.workflow_id)
    {:ok, workflow} = WorkflowReducer.replay(events)
    state = %{state | replayed: MapSet.new(events, & &1.id)}
    resume(workflow, events, state)
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

  def handle_info({:proposal_produced, %Proposal{} = proposal, raw_output_blob_id}, state) do
    propose(%Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      proposal: proposal,
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
    propose(%Event.EffectFailed{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      intent: intent,
      reason: reason,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  ## Resume policy

  defp resume(%Workflow{status: :applying}, events, state) do
    case List.last(events) do
      %Event.EffectApplicationStarted{} ->
        fail_interrupted_effects(state)

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

  defp resume(_workflow, events, state), do: react(List.last(events), state)

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
    {:noreply, start_proposal_production(state)}
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
    event =
      case IntentValidator.validate(proposal) do
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

  defp react(%Event.ProposalApproved{}, state) do
    propose(%Event.EffectApplicationStarted{
      id: Id.generate(),
      workflow_id: state.workflow_id,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp react(%Event.EffectApplicationStarted{}, state) do
    start_effect_application(state)
    {:noreply, state}
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

  defp react(%Event.ProposalRejected{}, state) do
    {:noreply, state}
  end

  defp react(%Event.EffectApplied{}, state) do
    {:noreply, state}
  end

  defp react(%Event.WorkflowFailed{}, state) do
    {:noreply, state}
  end

  defp react(%Event.WorkflowCompleted{}, state) do
    {:noreply, state}
  end

  ## Proposal production

  defp start_proposal_production(state) do
    builder = :persistent_term.get(:proposal_builder, Current.ProposalBuilder)
    orchestrator = self()
    request = state.request
    workflow_id = state.workflow_id

    pid =
      spawn_link(fn ->
        message =
          case builder.build(request, workflow_id) do
            {:ok, %Proposal{} = proposal} ->
              raw_output_blob_id = nil
              {:proposal_produced, proposal, raw_output_blob_id}

            {:ok, %Proposal{} = proposal, raw_output_blob_id} ->
              {:proposal_produced, proposal, raw_output_blob_id}

            {:error, %ProposalProductionError{} = err} ->
              {:proposal_production_failed, err}
          end

        send(orchestrator, message)
      end)

    %{state | proposal_production: %{pid: pid}}
  end

  ## Effect application

  defp start_effect_application(state) do
    orchestrator = self()
    {:ok, workflow} = Current.WorkflowStore.get(state.workflow_id)

    intents = workflow.proposal.intents

    spawn_link(fn ->
      try do
        case apply_intents_streaming(
               intents,
               orchestrator,
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

  defp apply_intents_streaming([], _orchestrator, acc) do
    {:ok, :lists.reverse(acc)}
  end

  defp apply_intents_streaming(
         [intent | rest],
         orchestrator,
         acc
       ) do
    applicator =
      :persistent_term.get(
        :effect_applicator,
        Current.EffectApplicator
      )

    case applicator.apply(intent, acc) do
      {:ok, result} ->
        send(
          orchestrator,
          {:effect_applied, intent, result}
        )

        apply_intents_streaming(
          rest,
          orchestrator,
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
end
