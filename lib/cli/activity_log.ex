defmodule Current.ActivityLog do
  @moduledoc """
  Prints what the runtime is doing to the node's console, one line each:
  RPC requests as they arrive, and every commit as it is written to the
  WAL (consensus log), tagged with the task it belongs to.

      18:51:40.093  ← submit_task      plan "Add rate limiting to the login endpoint"
                                       /Users/you/current/examples/nextjs-auth
      18:51:40.094  → submit_task      accepted as task f8dfe4612297
      18:51:40.101  WAL #13  2f9c1a0e  TaskCreated                task f8dfe4612297  plan · "Add rate limiting…"
      18:51:40.108  WAL #14  8be41c77  WorkflowCreated            task f8dfe4612297  workflow 03dfd3178577
      18:51:52.884  WAL #16  c01d9e52  ProposalProduced           task f8dfe4612297  proposal 412dbfaf2078 · 7 intents · model 12.8s
      18:51:52.891  WAL #18  51aa07b3  WorkflowCompleted          task f8dfe4612297  planned · 12.8s total

  The hash is the first 8 hex digits of the commit's own hash -- what the
  next commit records as its previous_hash.

  It listens to Consensus.SingleNodeServer, so a line appears once the
  commit is durable in the WAL, which is before EventStore has applied
  it. (EventCommitter logs an error if EventStore later rejects one.)
  Its child position in Consensus.Supervisor (`:rest_for_one`, after
  SingleNodeServer) makes it re-subscribe whenever SingleNodeServer is
  replaced, as EventCommitter does.

  Output is only printed while `config :current, activity_log: true`;
  `bin/current-server` turns it on. Otherwise the process just keeps
  its bookkeeping, so tests stay quiet. It never affects the runtime:
  every call into it is a cast.

  Repeated identical RPC requests (a client polling `workflow/1`) are
  printed once, and again only after a pause of 2 seconds.
  """

  use GenServer

  alias Current.Consensus.{Commit, SingleNodeServer}
  alias Current.Event
  alias Current.Error.{ProposalProductionError, ValidationError}

  @repeat_window_ms 2_000
  @detail_width 70

  ## Client API

  def start_link(opts \\ []) do
    {consensus, opts} = Keyword.pop(opts, :consensus, SingleNodeServer)
    GenServer.start_link(__MODULE__, consensus, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Records an RPC request. `detail` is a list of already-formatted lines."
  @spec rpc(atom(), [String.t()]) :: :ok
  def rpc(function, detail \\ []) do
    GenServer.cast(__MODULE__, {:rpc, function, detail, now()})
  end

  @doc "Records how an RPC request that changes something turned out."
  @spec rpc_result(atom(), String.t()) :: :ok
  def rpc_result(function, outcome) do
    GenServer.cast(__MODULE__, {:rpc_result, function, outcome, now()})
  end

  ## Server

  @impl true
  def init(consensus) do
    :ok = SingleNodeServer.subscribe(consensus, self())

    {:ok,
     %{
       # workflow_id => task_id, learnt from WorkflowCreated
       tasks: %{},
       # task_id => monotonic ms at TaskCreated
       started: %{},
       # workflow_id => monotonic ms at ProposalProductionStarted
       producing: %{},
       # {function, detail} => monotonic ms of the last such request
       recent_rpcs: %{}
     }}
  end

  @impl true
  def handle_info({:consensus_confirmed, %Commit{} = commit}, state) do
    hash = commit |> Commit.hash() |> Base.encode16(case: :lower) |> binary_part(0, 8)
    at = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(commit.events, state, fn event, state ->
        state = track(event, state, at)
        print(commit_line(commit.index, hash, event, state, at))
        forget(event, state)
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:rpc, function, detail, {wall, mono}}, state) do
    key = {function, detail}
    last = Map.get(state.recent_rpcs, key)

    if last == nil or mono - last > @repeat_window_ms do
      [first | rest] = if detail == [], do: [""], else: detail

      print(
        String.trim_trailing(
          "#{wall}  ← #{String.pad_trailing(Atom.to_string(function), 15)}  #{first}"
        )
      )

      Enum.each(rest, &print("#{String.duplicate(" ", 33)}#{&1}"))
    end

    recent =
      state.recent_rpcs
      |> Map.reject(fn {_key, at} -> mono - at > @repeat_window_ms end)
      |> Map.put(key, mono)

    {:noreply, %{state | recent_rpcs: recent}}
  end

  def handle_cast({:rpc_result, function, outcome, {wall, _mono}}, state) do
    print("#{wall}  → #{String.pad_trailing(Atom.to_string(function), 15)}  #{outcome}")
    {:noreply, state}
  end

  ## Bookkeeping

  defp track(%Event.TaskCreated{task_id: task_id}, state, at),
    do: put_in(state.started[task_id], at)

  defp track(%Event.WorkflowCreated{workflow_id: workflow_id, task_id: task_id}, state, _at),
    do: put_in(state.tasks[workflow_id], task_id)

  defp track(%Event.ProposalProductionStarted{workflow_id: workflow_id}, state, at),
    do: put_in(state.producing[workflow_id], at)

  defp track(_event, state, _at), do: state

  defp forget(%{workflow_id: workflow_id} = event, state) do
    if terminal?(event) do
      task_id = Map.get(state.tasks, workflow_id)

      %{
        state
        | tasks: Map.delete(state.tasks, workflow_id),
          started: Map.delete(state.started, task_id),
          producing: Map.delete(state.producing, workflow_id)
      }
    else
      state
    end
  end

  defp forget(_event, state), do: state

  defp terminal?(event) do
    match?(%Event.WorkflowCompleted{}, event) or match?(%Event.WorkflowFailed{}, event) or
      match?(%Event.WorkflowAbandoned{}, event)
  end

  ## Formatting

  defp commit_line(index, hash, event, state, at) do
    {wall, _mono} = now()

    Enum.join(
      [
        wall,
        String.pad_trailing("WAL ##{index}", 8),
        hash,
        String.pad_trailing(event_name(event), 26),
        String.pad_trailing(owner(event, state), 17),
        truncate(detail(event, state, at))
      ],
      "  "
    )
    |> String.trim_trailing()
  end

  # Which task an event belongs to. A workflow resumed from before this
  # process started has no WorkflowCreated here, so it shows as itself.
  defp owner(%Event.TaskCreated{task_id: task_id}, _state), do: "task " <> short(task_id)

  defp owner(%{workflow_id: workflow_id}, state) do
    case Map.get(state.tasks, workflow_id) do
      nil -> "workflow " <> short(workflow_id)
      task_id -> "task " <> short(task_id)
    end
  end

  defp owner(_event, _state), do: ""

  defp detail(%Event.TaskCreated{mode: mode, input: input}, _state, _at),
    do: "#{mode} · #{inspect(input)}"

  defp detail(%Event.WorkflowCreated{workflow_id: workflow_id}, _state, _at),
    do: "workflow " <> short(workflow_id)

  defp detail(%Event.ProposalProduced{proposal: proposal, workflow_id: workflow_id}, state, at) do
    count = length(proposal.intents)

    Enum.join(
      [
        "proposal " <> short(proposal.id),
        "#{count} #{if count == 1, do: "intent", else: "intents"}"
        | since("model", Map.get(state.producing, workflow_id), at)
      ],
      " · "
    )
  end

  defp detail(%Event.ProposalProductionFailed{error: error, workflow_id: workflow_id}, state, at),
    do:
      Enum.join(
        [
          ProposalProductionError.message(error)
          | since("after", Map.get(state.producing, workflow_id), at)
        ],
        " · "
      )

  defp detail(
         %Event.ProposalValidationFailed{error: %ValidationError{reason: reason}},
         _state,
         _at
       ),
       do: reason

  defp detail(%Event.EffectApplied{intent: intent}, _state, _at), do: intent_name(intent)

  defp detail(%Event.EffectFailed{intent: intent, reason: reason}, _state, _at),
    do: "#{intent_name(intent)}: #{text(reason)}"

  defp detail(%Event.WorkflowCompleted{workflow_id: workflow_id}, state, at),
    do: Enum.join(["completed" | total(workflow_id, state, at)], " · ")

  defp detail(%Event.WorkflowFailed{workflow_id: workflow_id, reason: reason}, state, at),
    do: Enum.join([text(reason) | total(workflow_id, state, at)], " · ")

  defp detail(%Event.WorkflowAbandoned{workflow_id: workflow_id, reason: reason}, state, at),
    do: Enum.join([text(reason) | total(workflow_id, state, at)], " · ")

  defp detail(%Event.ModeInvalid{mode: mode}, _state, _at), do: inspect(mode)
  defp detail(_event, _state, _at), do: ""

  defp total(workflow_id, state, at) do
    started = state.tasks |> Map.get(workflow_id) |> then(&Map.get(state.started, &1))
    since("total", started, at)
  end

  defp since(_label, nil, _at), do: []

  defp since(label, from, at),
    do: ["#{label} #{:erlang.float_to_binary((at - from) / 1000, decimals: 1)}s"]

  defp intent_name(%{__struct__: mod} = intent) do
    name = mod |> Module.split() |> List.last()

    case Map.get(intent, :path) || Map.get(intent, :cmd) do
      nil -> name
      target -> "#{name} #{target}"
    end
  end

  defp event_name(%{__struct__: mod}), do: mod |> Module.split() |> List.last()

  defp short("sha256:" <> hex), do: binary_part(hex, 0, min(12, byte_size(hex)))
  defp short(id) when is_binary(id), do: id
  defp short(id), do: inspect(id)

  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)

  defp truncate(text) do
    text = text |> String.split("\n") |> hd()

    if String.length(text) > @detail_width,
      do: String.slice(text, 0, @detail_width - 1) <> "…",
      else: text
  end

  ## Output

  defp print(line) do
    if Application.get_env(:current, :activity_log, false), do: IO.puts(line)
    :ok
  end

  defp now do
    # Local time with milliseconds, like Logger's console output.
    us = System.os_time(:microsecond)
    {_date, {h, m, sec}} = :calendar.system_time_to_local_time(us, :microsecond)
    ms = us |> div(1000) |> rem(1000)

    wall =
      :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, sec, ms]) |> IO.iodata_to_binary()

    {wall, System.monotonic_time(:millisecond)}
  end
end
