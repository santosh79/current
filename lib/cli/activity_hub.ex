defmodule Current.ActivityHub do
  @moduledoc """
  What the runtime is doing right now, per workflow, as a live view.

  The hub listens to two things:

    * every commit Consensus.SingleNodeServer writes to the WAL (the
      same feed ActivityLog used to subscribe to directly), from which it
      keeps the small amount of per-workflow bookkeeping the console needs:
      which task a workflow belongs to, when production started, when the
      task began;
    * what a model is shown while it works out its proposal. Each round of
      context requests is reported by Current.LLMProposalBuilder, tagged
      with its workflow id, twice: when the model has asked
      (`observe_requested/3`) and when the runtime has settled each
      request as shown or refused (`observe_settled/3`).

  It accepts subscribers (`subscribe/2`) and tells each of them when
  something changed, as a delta rather than the whole state:

      {:activity, workflow_id, %{type: :commit, ...}}
      {:activity, workflow_id, %{type: :requested | :settled, round: 1, ...}}
      {:activity, nil,         %{type: :api | :api_result, ...}}

  `workflow_id` is nil for something that belongs to no workflow yet (a
  TaskCreated commit, an API request). Subscribers are monitored and
  dropped when they exit, and nothing here ever waits for one.

  HTTP clients don't subscribe. They poll `activity/3` -- see
  `Current.API.activity/3` -- with the epoch and sequence number of the
  last item they saw, and get what came after it. The epoch is picked when
  the hub starts, so a client that last spoke to an earlier hub is given
  everything the new one has, instead of a sequence number that now means
  something else.

  ## This is a live view, not a record

  Nothing the hub holds is durable and no event is committed for it. What
  a model looked at is recorded where it always was: on the proposal
  (`Current.Proposal.observations`), by id. The hub only makes it visible
  *while it happens*. Memory is bounded: it keeps the newest
  100 items of each workflow, and the 100 workflows with the most
  recent activity (finished or not); beyond that, and across a restart of
  the hub, it forgets.

  Every call into it is a cast (or, for `activity/2` and `subscribe/2`, a
  call that can't affect the runtime), so it can never slow down or break
  the work it describes.
  """

  use GenServer

  alias Current.Consensus.{Commit, SingleNodeServer}
  alias Current.Event
  alias Current.Observation

  # The most items kept per workflow, and the most workflows (and unclaimed
  # task starts) kept. The oldest goes first.
  @max_items 100
  @max_workflows 100

  ## Client API

  def start_link(opts \\ []) do
    {consensus, opts} = Keyword.pop(opts, :consensus, SingleNodeServer)
    GenServer.start_link(__MODULE__, consensus, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes `pid` (default: the caller) to activity for one workflow, or
  to all of it with `:all`. The subscriber receives
  `{:activity, workflow_id, delta}` messages until it exits or calls
  `unsubscribe/2`.
  """
  @spec subscribe(GenServer.server(), :all | Current.Id.t(), pid()) :: :ok
  def subscribe(hub, filter, pid) when is_pid(pid) do
    GenServer.call(hub, {:subscribe, pid, filter})
  end

  @spec subscribe(:all | Current.Id.t()) :: :ok
  def subscribe(filter \\ :all), do: subscribe(__MODULE__, filter, self())

  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(hub, pid) when is_pid(pid) do
    GenServer.call(hub, {:unsubscribe, pid})
  end

  @spec unsubscribe() :: :ok
  def unsubscribe, do: unsubscribe(__MODULE__, self())

  @doc """
  The activity of `workflow_id` after sequence number `after_seq`: the
  items in order, and the sequence number of the newest one, along with the
  hub's `epoch`. A workflow the hub doesn't know has none.

  `after_seq` only means something to the hub whose `epoch` the caller
  last saw. Pass nil the first time; if the epoch isn't this hub's, the
  caller gets everything this hub has.
  """
  @spec activity(GenServer.server(), Current.Id.t(), integer() | nil, non_neg_integer()) :: %{
          epoch: integer(),
          items: [map()],
          last_seq: non_neg_integer()
        }
  def activity(hub, workflow_id, epoch, after_seq)
      when is_binary(workflow_id) and is_integer(after_seq) do
    GenServer.call(hub, {:activity, workflow_id, epoch, after_seq})
  end

  def activity(workflow_id, epoch \\ nil, after_seq \\ 0),
    do: activity(__MODULE__, workflow_id, epoch, after_seq)

  @doc """
  The model has asked to see `observations` (round `round` of its
  conversation). Called by the proposal builder, in its own process.
  """
  @spec observe_requested(Current.Id.t(), pos_integer(), [Observation.t()]) :: :ok
  def observe_requested(workflow_id, round, observations) do
    entries = Enum.map(observations, &%{label: label(&1.intent), reason: &1.reason})
    GenServer.cast(__MODULE__, {:observe, workflow_id, :requested, round, entries})
  end

  @doc """
  The runtime has settled round `round`: `made` is what Current.Observer
  returned, each settled observation with the text the model was shown.
  Only sizes are kept, never contents.
  """
  @spec observe_settled(Current.Id.t(), pos_integer(), [{Observation.t(), String.t()}]) :: :ok
  def observe_settled(workflow_id, round, made) do
    entries =
      Enum.map(made, fn {%Observation{} = observation, text} ->
        %{
          label: label(observation.intent),
          status: observation.status,
          bytes: if(observation.status == :shown, do: byte_size(text)),
          error: observation.error
        }
      end)

    GenServer.cast(__MODULE__, {:observe, workflow_id, :settled, round, entries})
  end

  @doc "Records an API request. `detail` is a list of already-formatted lines."
  @spec api(atom(), [String.t()]) :: :ok
  def api(function, detail \\ []) do
    GenServer.cast(__MODULE__, {:api, :api, function, detail, stamp()})
  end

  @doc "Records how an API request that changes something turned out."
  @spec api_result(atom(), String.t()) :: :ok
  def api_result(function, outcome) do
    GenServer.cast(__MODULE__, {:api, :api_result, function, outcome, stamp()})
  end

  @doc "What an observation asked for, as the model wrote it."
  @spec label(Observation.intent() | struct()) :: String.t()
  def label(%Current.Intent.ReadFile{path: path}), do: "read_file #{path}"

  def label(%Current.Intent.Glob{pattern: pattern, base_dir: base_dir})
      when base_dir in [nil, "."],
      do: "glob #{pattern}"

  def label(%Current.Intent.Glob{pattern: pattern, base_dir: base_dir}),
    do: "glob #{pattern} in #{base_dir}"

  def label(%Current.Intent.Grep{pattern: pattern, paths: paths}),
    do: "grep #{inspect(pattern)} in #{Enum.join(paths, ", ")}"

  def label(%{__struct__: mod}), do: mod |> Module.split() |> List.last()

  ## Server

  @impl true
  def init(consensus) do
    :ok = SingleNodeServer.subscribe(consensus, self())

    {:ok,
     %{
       # Different for every incarnation of the hub; see activity/4.
       epoch: System.os_time(:microsecond),
       # workflow_id => %{task_id, task_started, producing, seq, items, touched}
       workflows: %{},
       # task_id => monotonic ms at TaskCreated, until WorkflowCreated claims it
       task_starts: %{},
       # pid => %{ref, filter}
       subscribers: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, pid, filter}, _from, state) do
    subscribers =
      Map.update(state.subscribers, pid, %{ref: Process.monitor(pid), filter: filter}, fn sub ->
        %{sub | filter: filter}
      end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, drop(state, pid)}
  end

  def handle_call({:activity, workflow_id, epoch, after_seq}, _from, state) do
    workflow = Map.get(state.workflows, workflow_id, new_workflow())
    after_seq = if epoch == state.epoch, do: after_seq, else: 0

    items = workflow.items |> Enum.filter(&(&1.seq > after_seq)) |> Enum.reverse()
    {:reply, %{epoch: state.epoch, items: items, last_seq: workflow.seq}, state}
  end

  @impl true
  def handle_info({:consensus_confirmed, %Commit{} = commit}, state) do
    hash = commit |> Commit.hash() |> Base.encode16(case: :lower) |> binary_part(0, 8)
    at = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(commit.events, state, fn event, state ->
        state = track(event, state, at)
        workflow_id = Map.get(event, :workflow_id)
        workflow = Map.get(state.workflows, workflow_id, new_workflow())

        notify(state, workflow_id, %{
          type: :commit,
          index: commit.index,
          hash: hash,
          event: event,
          at: at,
          task_id: task_of(event, workflow),
          task_started: workflow.task_started || task_start(event, state),
          producing: workflow.producing
        })

        state
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:observe, workflow_id, type, round, entries}, state) do
    workflow = Map.get(state.workflows, workflow_id, new_workflow())
    seq = workflow.seq + 1
    item = %{seq: seq, round: round, type: type, entries: entries}

    workflow = %{workflow | seq: seq, items: Enum.take([item | workflow.items], @max_items)}
    state = put_workflow(state, workflow_id, workflow)

    notify(state, workflow_id, Map.put(item, :task_id, workflow.task_id))
    {:noreply, state}
  end

  def handle_cast({:api, type, function, detail, {wall_us, mono}}, state) do
    notify(state, nil, %{
      type: type,
      function: function,
      detail: detail,
      wall_us: wall_us,
      mono: mono
    })

    {:noreply, state}
  end

  ## Bookkeeping

  defp new_workflow,
    do: %{task_id: nil, task_started: nil, producing: nil, seq: 0, items: [], touched: nil}

  # Every write goes through here, so the number of workflows kept is
  # bounded: past @max_workflows, the one touched longest ago is dropped.
  defp put_workflow(state, workflow_id, workflow) do
    workflow = %{workflow | touched: System.monotonic_time()}
    workflows = Map.put(state.workflows, workflow_id, workflow)

    workflows =
      if map_size(workflows) > @max_workflows do
        {oldest, _} = Enum.min_by(workflows, fn {_id, w} -> w.touched end)
        Map.delete(workflows, oldest)
      else
        workflows
      end

    %{state | workflows: workflows}
  end

  # Same bound for task starts that no WorkflowCreated ever claims.
  defp track(%Event.TaskCreated{task_id: task_id}, state, at) do
    task_starts = Map.put(state.task_starts, task_id, at)

    task_starts =
      if map_size(task_starts) > @max_workflows do
        {oldest, _} = Enum.min_by(task_starts, fn {_id, started} -> started end)
        Map.delete(task_starts, oldest)
      else
        task_starts
      end

    %{state | task_starts: task_starts}
  end

  defp track(%Event.WorkflowCreated{workflow_id: workflow_id, task_id: task_id}, state, _at) do
    {started, task_starts} = Map.pop(state.task_starts, task_id)
    workflow = Map.get(state.workflows, workflow_id, new_workflow())

    put_workflow(state, workflow_id, %{workflow | task_id: task_id, task_started: started})
    |> Map.put(:task_starts, task_starts)
  end

  defp track(%Event.ProposalProductionStarted{workflow_id: workflow_id}, state, at) do
    workflow = Map.get(state.workflows, workflow_id, new_workflow())
    put_workflow(state, workflow_id, %{workflow | producing: at})
  end

  defp track(_event, state, _at), do: state

  # A TaskCreated commit has no workflow yet; its start time is in task_starts.
  defp task_start(%Event.TaskCreated{task_id: task_id}, state),
    do: Map.get(state.task_starts, task_id)

  defp task_start(_event, _state), do: nil

  defp task_of(%Event.TaskCreated{task_id: task_id}, _workflow), do: task_id
  defp task_of(_event, workflow), do: workflow.task_id

  ## Subscribers

  defp notify(state, workflow_id, delta) do
    Enum.each(state.subscribers, fn {pid, %{filter: filter}} ->
      if filter == :all or filter == workflow_id,
        do: send(pid, {:activity, workflow_id, delta})
    end)
  end

  defp drop(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {%{ref: ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  # Wall clock (microseconds) for display, monotonic ms for ordering and windows.
  defp stamp, do: {System.os_time(:microsecond), System.monotonic_time(:millisecond)}
end
