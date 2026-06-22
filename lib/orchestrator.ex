defmodule Current.WorkflowOrchestrator do
  use GenServer

  alias Current.Event

  @type state :: %{
          listeners: [pid()],
          workflow_pid: pid() | nil
        }

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    listeners = Keyword.get(opts, :listeners, [])
    GenServer.start_link(__MODULE__, %{listeners: listeners, workflow_pid: nil})
  end

  ## Server callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:workflow_created, workflow_pid, %Current.Workflow{} = workflow}, state)
      when is_pid(workflow_pid) do
    :ok =
      append_event(%Event.WorkflowCreated{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:workflow_created, workflow.task_id, workflow})

    case Current.Mode.valid?(workflow.mode) do
      true ->
        GenServer.cast(workflow_pid, :start_planning)

      _ ->
        GenServer.cast(workflow_pid, :mark_mode_invalid)
    end

    {:noreply, %{state | workflow_pid: workflow_pid}}
  end

  @impl true
  def handle_info({:mode_invalid, %Current.Workflow{} = workflow, mode}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ModeInvalid{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        mode: mode,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:mode_invalid, workflow.task_id, workflow, mode})
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_production_started, %Current.Workflow{} = workflow}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ProposalProductionStarted{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:proposal_production_started, workflow.task_id, workflow})
    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_produced, %Current.Workflow{} = workflow}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ProposalProduced{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:proposal_produced, workflow.task_id, workflow, workflow.proposal}
    )

    case Current.IntentValidator.validate(workflow.proposal) do
      :ok ->
        GenServer.cast(state.workflow_pid, :mark_proposal_validated)

      {:error, %Current.Error.ValidationError{} = error} ->
        GenServer.cast(state.workflow_pid, {:mark_proposal_validation_failed, error})
    end

    {:noreply, state}
  end

  def handle_info({:proposal_validated, %Current.Workflow{} = workflow}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ProposalValidated{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        proposal: workflow.proposal,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:proposal_validated, workflow.task_id, workflow, workflow.proposal}
    )

    case workflow.mode do
      :plan -> GenServer.cast(state.workflow_pid, :complete_as_plan)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info(
        {:proposal_validation_failed, %Current.Workflow{} = workflow,
         %Current.Error.ValidationError{} = error},
        state
      )
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ProposalValidationFailed{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        proposal: workflow.proposal,
        error: error,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:proposal_validation_failed, workflow.task_id, workflow, error}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_decision_made, proposal_id, decision}, state)
      when is_pid(state.workflow_pid) do
    GenServer.cast(state.workflow_pid, {:record_proposal_decision, proposal_id, decision})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:proposal_decision_recorded, {:approve, _metadata} = _decision,
         %Current.Workflow{} = workflow},
        state
      )
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ProposalApproved{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:proposal_approved, workflow.task_id, workflow})
    GenServer.cast(state.workflow_pid, :apply_effects)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:proposal_decision_recorded, {:reject, _metadata} = _decision,
         %Current.Workflow{} = workflow},
        state
      )
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ProposalRejected{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:proposal_rejected, workflow.task_id, workflow})
    {:noreply, state}
  end

  @impl true
  def handle_info({:effect_application_started, %Current.Workflow{} = workflow}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.EffectApplicationStarted{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.FilePatch{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.WriteFile{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.RunCommand{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.ReadFile{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.Glob{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.Grep{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.Claim{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  def handle_info(
        {:effect_applied, %Current.Workflow{} = workflow, %Current.Intent.Report{} = intent,
         result},
        state
      )
      when is_pid(state.workflow_pid), do: handle_effect_applied(workflow, intent, result, state)

  @impl true
  def handle_info({:effects_applied, %Current.Workflow{} = workflow, intent_results}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.EffectsApplied{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        intent_results: intent_results,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:effects_applied, workflow.task_id, workflow, intent_results}
    )

    GenServer.cast(state.workflow_pid, {:produce_artifacts, intent_results})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.FilePatch{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.WriteFile{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.ReadFile{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.DeleteFile{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.RunCommand{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.Grep{} = intent, reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.Glob{} = intent, reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.Claim{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info(
        {:effect_failed, %Current.Workflow{} = workflow, %Current.Intent.Report{} = intent,
         reason},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_effect_failed(workflow, intent, reason, state)
  end

  @impl true
  def handle_info({:workflow_failed, %Current.Workflow{} = workflow}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.WorkflowFailed{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:workflow_failed, workflow.task_id, workflow})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.ReadFile{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.WriteFile{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.DeleteFile{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.FilePatch{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.RunCommand{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.Grep{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.Glob{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.Claim{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  def handle_info(
        {:artifact_produced, %Current.Workflow{} = workflow,
         {%Current.Intent.Report{} = intent, result}, %Current.Artifact{} = artifact},
        state
      )
      when is_pid(state.workflow_pid) do
    handle_artifact_produced(workflow, intent, result, state, artifact)
  end

  @impl true
  def handle_info(
        {:artifacts_produced, %Current.Workflow{} = workflow,
         [%Current.Artifact{} | _] = artifacts},
        state
      )
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.ArtifactsProduced{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        artifacts: artifacts,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:artifacts_produced, workflow.task_id, workflow, artifacts}
    )

    GenServer.cast(state.workflow_pid, {:assemble_result, artifacts})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:workflow_result_assembled, %Current.Workflow{} = workflow,
         %Current.WorkflowResult{} = result},
        state
      )
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.WorkflowResultAssembled{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        result: result,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:workflow_result_assembled, workflow.task_id, workflow, result}
    )

    GenServer.cast(state.workflow_pid, :complete)
    {:noreply, state}
  end

  @impl true
  def handle_info({:workflow_completed, %Current.Workflow{} = workflow}, state)
      when is_pid(state.workflow_pid) do
    :ok =
      append_event(%Event.WorkflowCompleted{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:workflow_completed, workflow.task_id, workflow})
    {:noreply, state}
  end

  defp append_event(event) do
    :ok = Current.EventStore.append(event)
    :ok
  end

  defp notify_listeners(listeners, message) do
    Enum.each(listeners, fn pid -> send(pid, message) end)
    :ok
  end

  defp handle_effect_applied(workflow, intent, result, state) do
    :ok =
      append_event(%Event.EffectApplied{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        intent: intent,
        result: result,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(
      state.listeners,
      {:effect_applied, workflow.task_id, workflow, intent, result}
    )

    {:noreply, state}
  end

  defp handle_effect_failed(workflow, intent, reason, state) do
    :ok =
      append_event(%Event.EffectFailed{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        intent: intent,
        reason: reason,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:effect_failed, workflow.task_id, workflow, reason})
    GenServer.cast(state.workflow_pid, {:fail, reason})
    {:noreply, state}
  end

  defp handle_artifact_produced(workflow, intent, result, state, artifact) do
    :ok =
      append_event(%Event.ArtifactProduced{
        id: Current.Id.generate(),
        workflow_id: workflow.id,
        workflow: workflow,
        intent: intent,
        result: result,
        artifact: artifact,
        timestamp: DateTime.utc_now()
      })

    notify_listeners(state.listeners, {:artifact_produced, workflow.task_id, workflow, artifact})
    {:noreply, state}
  end
end
