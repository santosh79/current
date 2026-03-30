defmodule Current.Workflow do
  use GenServer

  alias Current.{
    Id,
    Proposal,
    Intent,
    WorkflowStore,
    WorkflowOrchestrator,
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
    :workflow_artifact,
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
          | :assembling_artifact
          | :completed
          | :rejected
          | :failed

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          status: status(),
          proposal: Current.Proposal.t() | nil,
          workflow_artifact: Current.WorkflowArtifact.t() | nil,
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

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec create(Current.Id.t(), Request.t(), pid()) :: GenServer.on_start()
  def create(task_id, %Request{} = req, orchestrator_pid)
      when is_pid(orchestrator_pid) do
    workflow_id = Id.generate()

    start_link(
      task_id: task_id,
      workflow_id: workflow_id,
      request: req,
      orchestrator_pid: orchestrator_pid
    )
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
      workflow_artifact: nil,
      events: [],
      started_at: nil,
      created_at: now,
      completed_at: nil,
      updated_at: now,
      error: nil
    }

    :ok = TaskStore.put(task)
    :ok = WorkflowStore.put(workflow)

    :ok =
      WorkflowOrchestrator.notify_workflow_created(orchestrator_pid, self(), task_id, workflow)

    state = %{
      workflow: workflow,
      request: req,
      orchestrator_pid: orchestrator_pid
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(
        :produce_proposal,
        %{workflow: workflow, request: req, orchestrator_pid: orchestrator_pid} = state
      ) do
    proposal = build_proposal(req, workflow.id)

    updated_workflow = %{
      workflow
      | proposal: proposal,
        status: :validating,
        updated_at: DateTime.utc_now()
    }

    :ok = WorkflowStore.put(updated_workflow)

    :ok =
      WorkflowOrchestrator.notify_proposal_produced(
        orchestrator_pid,
        self(),
        workflow.task_id,
        updated_workflow,
        proposal
      )

    {:noreply, %{state | workflow: updated_workflow}}
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

    :ok =
      WorkflowOrchestrator.notify_workflow_planning(
        orchestrator_pid,
        self(),
        workflow.task_id,
        updated_workflow
      )

    {:noreply, %{state | workflow: updated_workflow}}
  end

  defp build_proposal(%Request{} = req, workflow_id) do
    proposal_id = Id.generate()

    intent = %Intent{
      id: Id.generate(),
      proposal_id: proposal_id,
      type: :file_patch,
      payload: %{
        path: "lib/my_app/signup.ex",
        diff: "...diff..."
      }
    }

    %Proposal{
      id: proposal_id,
      workflow_id: workflow_id,
      intents: [intent],
      justification: "Proposed changes for request: #{inspect(req.input)}",
      claims: [
        "invalid emails are rejected",
        "existing behavior is unchanged"
      ],
      dependencies: []
    }
  end
end
