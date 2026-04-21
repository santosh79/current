defmodule Current.Workflow do
  use GenServer

  alias Current.{
    Id,
    Proposal,
    WorkflowStore,
    TaskStore,
    Task,
    Request
  }

  @enforce_keys [:id, :task_id, :status, :created_at]
  defstruct [
    :id,
    :task_id,
    :status,
    :proposal,
    :result,
    :events,
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
  | :approved
  | :applying
  | :assembling_result
  | :completed
  | :rejected
  | :failed

  @type t :: %__MODULE__{
    id: Current.Id.t(),
    task_id: Current.Id.t(),
    status: status(),
    proposal: Current.Proposal.t() | nil,
    result: Current.WorkflowResult.t() | nil,
    events: [Current.Event.t()],
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

  @type workflow_event ::
  {:workflow_created, pid(), t()}
  | {:proposal_production_started, t()}
  | {:proposal_produced, t()}
  | {:effect_application_started, t()}
  | {:effect_applied, t(), Current.Intent.t(), map()}
  | {:effects_applied, t(), [{Current.Intent.t(), map()}]}
  | {:effect_failed, t(), Current.Intent.t(), String.t()}
  | {:artifact_produced, t(), Current.Artifact.t()}
  | {:workflow_result_assembled, t(), Current.WorkflowResult.t()}
  | {:workflow_completed, t()}

  @type workflow_command ::
  :start_planning
  | :produce_proposal
  | {:review_proposal, Current.Id.t(), Current.decision()}
  | :apply_effects
  | :produce_artifact
  | {:assemble_result, [Current.Artifact.t()]}
  | :complete

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

  @spec produce_proposal(pid()) :: :ok
  def produce_proposal(workflow_pid) when is_pid(workflow_pid) do
    GenServer.cast(workflow_pid, :produce_proposal)
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

    workflow = %__MODULE__{
      id: workflow_id,
      task_id: task_id,
      status: :created,
      proposal: nil,
      result: nil,
      events: [],
      started_at: nil,
      created_at: now,
      completed_at: nil,
      updated_at: now,
      error: nil
    }

    :ok = TaskStore.put(task)
    :ok = WorkflowStore.put(workflow)

    send(orchestrator_pid, {:workflow_created, self(), workflow})

    state = %{
      workflow: workflow,
      request: req,
      orchestrator_pid: orchestrator_pid
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(
    :start_planning,
    %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state
  ) do
    updated_workflow = %{
      workflow
      | status: :planning,
      started_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ok = WorkflowStore.put(updated_workflow)

    send(orchestrator_pid, {:proposal_production_started, updated_workflow})

    updated_workflow = produce_proposal(state, updated_workflow)

    {:noreply, %{state | workflow: updated_workflow}}
  end

  @impl true
  def handle_cast(
    {:record_proposal_decision, proposal_id, {:approve, _metadata} = decision},
    %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state
  ) do
    case workflow.proposal do
      %Proposal{id: ^proposal_id} ->
        updated_workflow = %{
        workflow
        | status: :approved,
        updated_at: DateTime.utc_now()
      }

        :ok = WorkflowStore.put(updated_workflow)
        send(orchestrator_pid, {:proposal_decision_recorded, decision, updated_workflow})

        {:noreply, %{state | workflow: updated_workflow}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(
    {:record_proposal_decision, proposal_id, {:reject, _metadata} = decision},
    %{workflow: %Current.Workflow{} = workflow, orchestrator_pid: orchestrator_pid} = state
  ) do
    case workflow.proposal do
      %Proposal{id: ^proposal_id} ->
        updated_workflow = %{
        workflow
        | status: :rejected,
        updated_at: DateTime.utc_now()
      }

        :ok = WorkflowStore.put(updated_workflow)
        send(orchestrator_pid, {:proposal_decision_recorded, decision, updated_workflow})

        {:noreply, %{state | workflow: updated_workflow}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(
    :apply_effects,
    %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state
  ) do

    updated_workflow = %{workflow | status: :applying, updated_at: DateTime.utc_now()}
    :ok = WorkflowStore.put(updated_workflow)
    send(orchestrator_pid, {:effect_application_started, updated_workflow})

    case apply_intents_streaming(workflow.proposal.intents, orchestrator_pid, updated_workflow, []) do
      {:ok, intent_results} ->
        send(orchestrator_pid, {:effects_applied, updated_workflow, intent_results})
        {:noreply, %{state | workflow: updated_workflow}}

      {:error, intent, reason} ->
        send(orchestrator_pid, {:effect_failed, updated_workflow, intent, reason})
        {:noreply, %{state | workflow: updated_workflow}}
    end
  end

  @impl true
  def handle_cast({:fail, reason}, %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state) do
    updated_workflow = %{
      workflow
      | status: :failed,
      error: reason,
      updated_at: DateTime.utc_now()
    }

    :ok = WorkflowStore.put(updated_workflow)
    send(orchestrator_pid, {:workflow_failed, updated_workflow})
    {:noreply, %{state | workflow: updated_workflow}}
  end

  @impl true
  def handle_cast(
    {:produce_artifacts, intent_results},
    %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state
  ) do
    artifacts = intent_results |>
      Enum.map(fn(ir) ->
        {:ok, art} = Current.ArtifactBuilder.build(workflow, ir)
        send(orchestrator_pid, {:artifact_produced, workflow, ir, art})
        art
      end)
    send(orchestrator_pid, {:artifacts_produced, workflow, artifacts})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
    {:assemble_result, artifacts},
    %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state
  ) do
    result = build_workflow_result(workflow, artifacts)

    updated_workflow = %{
      workflow
      | status: :assembling_result,
      result: result,
      updated_at: DateTime.utc_now()
    }

    :ok = WorkflowStore.put(updated_workflow)
    send(orchestrator_pid, {:workflow_result_assembled, updated_workflow, result})
    {:noreply, %{state | workflow: updated_workflow}}
  end

  @impl true
  def handle_cast(:complete, %{workflow: workflow, orchestrator_pid: orchestrator_pid} = state) do
    updated_workflow = %{
      workflow
      | status: :completed,
      completed_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ok = WorkflowStore.put(updated_workflow)
    send(orchestrator_pid, {:workflow_completed, updated_workflow})
    {:noreply, %{state | workflow: updated_workflow}}
  end

  defp produce_proposal(
    %{request: req, orchestrator_pid: orchestrator_pid},
    %Current.Workflow{} = workflow
  ) do
    builder = :persistent_term.get(:proposal_builder, Current.ProposalBuilder)
    {:ok, proposal} = builder.build(req, workflow.id)

    updated_workflow = %{
      workflow
      | proposal: proposal,
      status: :validating,
      updated_at: DateTime.utc_now()
    }

    :ok = WorkflowStore.put(updated_workflow)
    send(orchestrator_pid, {:proposal_produced, updated_workflow})
    updated_workflow
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

  defp apply_intents_streaming([], _orchestrator_pid, _workflow, acc) do
    {:ok, acc |> :lists.reverse}
  end

  defp apply_intents_streaming([intent | rest], orchestrator_pid, workflow, acc) do
    case Current.EffectApplicator.apply(intent) do
      {:ok, result} ->
        send(orchestrator_pid, {:effect_applied, workflow, intent, result})
        apply_intents_streaming(rest, orchestrator_pid, workflow, [{intent, result} | acc])

      {:error, reason} ->
        {:error, intent, reason}
    end
  end
end
