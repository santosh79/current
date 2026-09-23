defmodule Current.WorkflowRunner do
  @moduledoc """
  Wraps one workflow's WorkflowOrchestrator with bounded retry-with-backoff,
  so a workflow that crash-loops (e.g. a real LLM producing a proposal that
  reliably re-triggers the same bug on every resume) degrades to a durable
  WorkflowAbandoned for that one workflow, rather than either restarting
  forever or -- via WorkflowSupervisor's own restart-intensity limit --
  taking every other concurrent workflow down with it.

  The orchestrator is started monitored, not linked: a crash arrives here
  as a :DOWN this process decides how to respond to, never as an :EXIT
  that would propagate automatically. This is what lets WorkflowSupervisor
  itself stay a plain, low-drama DynamicSupervisor -- all the "how many
  times has this workflow failed and what do we do about it" logic lives
  here, per workflow, isolated from every sibling.
  """

  use GenServer
  require Logger

  alias Current.{Event, Id, Task, Workflow, WorkflowOrchestrator, WorkflowStore}

  defstruct [
    :workflow_id,
    :task,
    :listeners,
    :attempt,
    :orchestrator_pid,
    :orchestrator_ref,
    abandoning: false
  ]

  @type start_arg :: {Current.Id.t(), Task.t(), [pid()]}

  ## Client API

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({workflow_id, %Task{}, listeners} = arg)
      when is_binary(workflow_id) and is_list(listeners),
      do: GenServer.start_link(__MODULE__, arg)

  @spec child_spec(start_arg()) :: Supervisor.child_spec()
  def child_spec({workflow_id, %Task{}, _listeners} = arg) do
    %{
      id: workflow_id,
      start: {__MODULE__, :start_link, [arg]},
      # :transient here mirrors WorkflowOrchestrator's own restart
      # semantics one level up: WorkflowRunner itself only needs
      # restarting by WorkflowSupervisor if IT crashes abnormally (a bug
      # in this module, not in the orchestrator it manages) -- reaching
      # max attempts or a clean workflow completion both exit :normal.
      restart: :transient,
      type: :worker
    }
  end

  ## Server

  @impl true
  def init({workflow_id, task, listeners}) do
    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :workflow_abandoned)
    state = %__MODULE__{workflow_id: workflow_id, task: task, listeners: listeners, attempt: 0}
    {:ok, start_orchestrator(state)}
  end

  defp start_orchestrator(state) do
    {:ok, pid} = WorkflowOrchestrator.start({state.workflow_id, state.task, state.listeners})

    %{
      state
      | orchestrator_pid: pid,
        orchestrator_ref: Process.monitor(pid),
        attempt: state.attempt + 1
    }
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{orchestrator_ref: ref} = state)
      when reason in [:normal, :shutdown] do
    # Reached a terminal Workflow.status and stopped itself cleanly (see
    # WorkflowOrchestrator's terminal react/2 clauses) -- nothing to
    # retry. Exit normally so WorkflowSupervisor's :transient restart
    # leaves this alone too.
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{orchestrator_ref: ref} = state) do
    if state.attempt >= max_attempts() do
      Logger.error(
        "workflow #{state.workflow_id} orchestrator crashed #{state.attempt} times " <>
          "(last reason: #{inspect(reason)}); giving up"
      )

      case give_up(state, reason) do
        :proposed -> {:noreply, %{state | abandoning: true}}
        _not_proposed -> {:stop, :normal, state}
      end
    else
      backoff = backoff_ms(state.attempt)

      Logger.warning(
        "workflow #{state.workflow_id} orchestrator crashed (attempt #{state.attempt}, " <>
          "reason: #{inspect(reason)}); retrying in #{backoff}ms"
      )

      Process.send_after(self(), :retry, backoff)
      {:noreply, state}
    end
  end

  def handle_info(:retry, state), do: {:noreply, start_orchestrator(state)}

  def handle_info(
        {:event_committed, %Current.EventStore.Entry{event: %Event.WorkflowAbandoned{}} = entry},
        %{abandoning: true} = state
      ) do
    Enum.each(state.listeners, &send(&1, {:workflow_abandoned, entry.event}))
    {:stop, :normal, state}
  end

  # Proposed by the orchestrator itself (e.g. a legacy task with no
  # project_dir). The orchestrator notifies listeners and stops :normal,
  # and that :DOWN is what ends this runner -- nothing to do here.
  def handle_info(
        {:event_committed, %Current.EventStore.Entry{event: %Event.WorkflowAbandoned{}}},
        state
      ),
      do: {:noreply, state}

  defp give_up(state, reason) do
    case WorkflowStore.get(state.workflow_id) do
      {:ok, %Workflow{} = workflow} ->
        if Workflow.terminal?(workflow) do
          :already_terminal
        else
          event = %Event.WorkflowAbandoned{
            id: Id.generate(),
            workflow_id: state.workflow_id,
            reason:
              "orchestrator crashed #{state.attempt} times (last reason: #{inspect(reason)}); giving up",
            timestamp: DateTime.utc_now()
          }

          :ok = Current.Consensus.propose(event)
          :proposed
        end

      {:error, :not_found} ->
        :not_found
    end
  end

  defp backoff_ms(attempt) do
    (base_backoff_ms() * :math.pow(2, attempt - 1)) |> round() |> min(max_backoff_ms())
  end

  defp max_attempts, do: Application.get_env(:current, :workflow_runner_max_attempts, 5)
  defp base_backoff_ms, do: Application.get_env(:current, :workflow_runner_base_backoff_ms, 1_000)
  defp max_backoff_ms, do: Application.get_env(:current, :workflow_runner_max_backoff_ms, 30_000)
end
