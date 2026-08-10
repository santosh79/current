defmodule Current.WorkflowOrchestrator do
  @moduledoc """
  Process manager for a single workflow.

  With the event-sourced model, the orchestrator no longer builds events or
  copies workflow state — the `Current.Workflow` aggregate owns the stream
  (event → reduce → append → project). The orchestrator has exactly two jobs,
  both driven by the `{:workflow_event, event}` messages the aggregate sends:

    * **Notify** — translate each event into the listener message tuple that
      callers of `Current.submit_task/2` subscribe to (`notification/1`).
    * **React** — encode the workflow *policy*: which command to cast at the
      aggregate next, given the event that just happened (`react/2`). Examples:
      a produced proposal gets validated; an approved proposal triggers effect
      application; a validation failure fails the workflow.

  It also appends the task-level `TaskCreated` event (task stream, not workflow
  stream) and routes external proposal decisions to the aggregate.
  """

  use GenServer

  alias Current.{Error, Event, IntentValidator, Mode, RuntimeRegistry}

  @type state :: %{
          listeners: [pid()],
          workflow_pid: pid() | nil
        }

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    listeners = Keyword.get(opts, :listeners, [])
    task_id = Keyword.fetch!(opts, :task_id)
    req = Keyword.fetch!(opts, :req)

    {:ok, pid} = GenServer.start_link(__MODULE__, %{})
    send(pid, {:long_init, listeners, task_id, req})
    {:ok, pid}
  end

  ## Server callbacks

  @impl true
  def init(_args) do
    {:ok, %{listeners: [], workflow_pid: nil}}
  end

  @impl true
  def handle_info({:long_init, listeners, task_id, %Current.Request{} = req}, _state) do
    # Task-level fact. It has no workflow_id and belongs to the task stream,
    # not the workflow stream, so the reducer never sees it.
    {:ok, workflow_pid, workflow_id} = Current.Workflow.create(task_id, req, self())

    :ok =
      RuntimeRegistry.put(workflow_id, %{
        workflow_pid: workflow_pid,
        orchestrator_pid: self()
      })

    {:noreply, %{listeners: listeners, workflow_pid: workflow_pid}}
  end

  @impl true
  def handle_info({:workflow_event, event}, state) when is_pid(state.workflow_pid) do
    case notification(event) do
      nil ->
        :ok

      message ->
        :ok = notify_listeners(state.listeners, message)
        :ok = react(event, state.workflow_pid)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:proposal_decision_made, proposal_id, decision}, state)
      when is_pid(state.workflow_pid) do
    GenServer.cast(state.workflow_pid, {:record_proposal_decision, proposal_id, decision})
    {:noreply, state}
  end

  ## Listener notifications (event -> listener tuple, nil to skip)

  defp notification(%Event.WorkflowCreated{workflow_id: _w_id} = event) do
    {:workflow_created, event}
  end

  defp notification(%Event.ProposalProductionStarted{workflow_id: _w_id} = event) do
    {:proposal_production_started, event}
  end

  defp notification(%Event.ModeInvalid{workflow_id: _w_id} = event) do
    {:mode_invalid, event}
  end

  defp notification(%Event.ProposalProduced{workflow_id: _w_id} = event) do
    {:proposal_produced, event}
  end

  defp notification(%Event.ProposalValidated{workflow_id: _w_id} = event) do
    {:proposal_validated, event}
  end

  defp notification(%Event.ProposalValidationFailed{workflow_id: _w_id, error: _error} = event) do
    {:proposal_validation_failed, event}
  end

  defp notification(%Event.ProposalApproved{workflow_id: _w_id} = event) do
    {:proposal_approved, event}
  end

  defp notification(%Event.ProposalRejected{workflow_id: _w_id} = event) do
    {:proposal_rejected, event}
  end

  defp notification(%Event.EffectApplicationStarted{}), do: nil

  defp notification(
         %Event.EffectApplied{workflow_id: _w_id, intent: _intent, result: _result} = event
       ) do
    {:effect_applied, event}
  end

  defp notification(
         %Event.EffectsApplied{workflow_id: _w_id, intent_results: _intent_results} = event
       ) do
    {:effects_applied, event}
  end

  defp notification(%Event.EffectFailed{workflow_id: _w_id, reason: _reason} = event) do
    {:effect_failed, event}
  end

  defp notification(%Event.ArtifactProduced{workflow_id: _w_id, artifact: _artifact} = event) do
    {:artifact_produced, event}
  end

  defp notification(%Event.ArtifactsProduced{workflow_id: _w_id, artifacts: _artifacts} = event) do
    {:artifacts_produced, event}
  end

  defp notification(%Event.WorkflowResultAssembled{workflow_id: _w_id, result: _result} = event) do
    {:workflow_result_assembled, event}
  end

  defp notification(%Event.WorkflowCompleted{workflow_id: _w_id} = event) do
    {:workflow_completed, event}
  end

  defp notification(%Event.WorkflowFailed{workflow_id: _w_id} = event) do
    {:workflow_failed, event}
  end

  ## Policy (event -> next command for the aggregate)

  defp react(%Event.WorkflowCreated{workflow_id: w_id} = _event, workflow_pid) do
    {:ok, w} = Current.WorkflowStore.get(w_id)

    case Mode.valid?(w.mode) do
      true -> GenServer.cast(workflow_pid, :start_planning)
      _ -> GenServer.cast(workflow_pid, :mark_mode_invalid)
    end

    :ok
  end

  defp react(%Event.ModeInvalid{mode: mode}, workflow_pid) do
    GenServer.cast(workflow_pid, {:fail, "invalid mode: #{inspect(mode)}"})
    :ok
  end

  defp react(%Event.ProposalProduced{workflow_id: w_id}, workflow_pid) do
    {:ok, w} = Current.WorkflowStore.get(w_id)

    case IntentValidator.validate(w.proposal) do
      :ok ->
        GenServer.cast(workflow_pid, :mark_proposal_validated)

      {:error, %Error.ValidationError{} = error} ->
        GenServer.cast(workflow_pid, {:mark_proposal_validation_failed, error})
    end

    :ok
  end

  defp react(%Event.ProposalValidated{workflow_id: w_id}, workflow_pid) do
    {:ok, w} = Current.WorkflowStore.get(w_id)

    case w.mode do
      :plan ->
        GenServer.cast(workflow_pid, :complete_as_plan)

      :apply ->
        :ok
    end

    :ok
  end

  defp react(%Event.ProposalValidationFailed{}, workflow_pid) do
    GenServer.cast(workflow_pid, {:fail, "proposal validation failed"})
    :ok
  end

  defp react(%Event.ProposalApproved{}, workflow_pid) do
    GenServer.cast(workflow_pid, :apply_effects)
    :ok
  end

  defp react(%Event.EffectsApplied{intent_results: intent_results}, workflow_pid) do
    GenServer.cast(workflow_pid, {:produce_artifacts, intent_results})
    :ok
  end

  defp react(%Event.EffectFailed{reason: reason}, workflow_pid) do
    GenServer.cast(workflow_pid, {:fail, reason})
    :ok
  end

  defp react(%Event.ArtifactsProduced{artifacts: artifacts}, workflow_pid) do
    GenServer.cast(workflow_pid, {:assemble_result, artifacts})
    :ok
  end

  defp react(%Event.WorkflowResultAssembled{}, workflow_pid) do
    GenServer.cast(workflow_pid, :complete)
    :ok
  end

  # Terminal or fact-only events (:proposal_rejected, :workflow_completed,
  # :workflow_failed, per-effect facts, ...) trigger no further commands.
  defp react(_event, _workflow_pid), do: :ok

  ## Internals

  defp notify_listeners(listeners, message) do
    Enum.each(listeners, fn pid -> send(pid, message) end)
    :ok
  end
end
