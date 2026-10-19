defmodule Current.ActivityLog do
  @moduledoc """
  Prints what the runtime is doing to the node's console, one line each:
  API requests as they arrive, every commit as it is written to the WAL
  (consensus log), and what a model asks to see while it works out a
  proposal, all tagged with the task they belong to.

      18:51:40.093  ← submit_task      plan "Add rate limiting to the login endpoint"
                                       /Users/you/current/examples/nextjs-auth
      18:51:40.094  → submit_task      accepted as task f8dfe4612297
      18:51:40.101  WAL #13  2f9c1a0e  TaskCreated                task f8dfe4612297  plan · "Add rate limiting…"
      18:51:40.108  WAL #14  8be41c77  WorkflowCreated            task f8dfe4612297  workflow 03dfd3178577
      18:51:43.020  observe  round 1    task f8dfe4612297  asked to see 2 things
      18:51:43.024  observe  round 1    task f8dfe4612297  ✓ read_file lib/signup.ex · 1.2 KB
      18:51:43.024  observe  round 1    task f8dfe4612297  ✗ read_file .env · .env is excluded
      18:51:52.884  WAL #16  c01d9e52  ProposalProduced           task f8dfe4612297  proposal 412dbfaf2078 · 7 intents · model 12.8s
      18:51:52.891  WAL #18  51aa07b3  WorkflowCompleted          task f8dfe4612297  planned · 12.8s total

  The hash is the first 8 hex digits of the commit's own hash -- what the
  next commit records as its previous_hash.

  It is a subscriber of Current.ActivityHub, which does the listening
  (to the WAL, to the proposal builder, to the API layer) and the
  per-workflow bookkeeping; this module only decides how each change
  reads on a console. Its child position in Consensus.Supervisor
  (`:rest_for_one`, after the hub) makes it re-subscribe whenever the hub
  is replaced.

  A WAL line appears once the commit is durable in the WAL, which is
  before EventStore has applied it. (EventCommitter logs an error if
  EventStore later rejects one.)

  Output is only printed while `config :current, activity_log: true`;
  `bin/current-server` turns it on. Otherwise the process just keeps
  its bookkeeping, so tests stay quiet.

  Repeated identical API requests (a client polling `workflow/1`) are
  printed once, and again only after a pause of 2 seconds.
  """

  use GenServer

  alias Current.ActivityHub
  alias Current.Event
  alias Current.Error.{ProposalProductionError, ValidationError}

  @repeat_window_ms 2_000
  @detail_width 70

  ## Client API

  def start_link(opts \\ []) do
    {hub, opts} = Keyword.pop(opts, :hub, ActivityHub)
    GenServer.start_link(__MODULE__, hub, Keyword.put_new(opts, :name, __MODULE__))
  end

  ## Server

  @impl true
  def init(hub) do
    :ok = ActivityHub.subscribe(hub, :all, self())

    # {function, detail} => monotonic ms of the last such request
    {:ok, %{recent_requests: %{}}}
  end

  @impl true
  def handle_info({:activity, _workflow_id, %{type: :commit} = commit}, state) do
    print(commit_line(commit))
    {:noreply, state}
  end

  def handle_info({:activity, _workflow_id, %{type: type} = item}, state)
      when type in [:requested, :settled] do
    Enum.each(observe_lines(item), &print/1)
    {:noreply, state}
  end

  def handle_info({:activity, _workflow_id, %{type: :api} = request}, state) do
    %{function: function, detail: detail, mono: mono} = request
    key = {function, detail}
    last = Map.get(state.recent_requests, key)

    if last == nil or mono - last > @repeat_window_ms do
      [first | rest] = if detail == [], do: [""], else: detail

      print(
        String.trim_trailing(
          "#{wall(request.wall_us)}  ← #{String.pad_trailing(Atom.to_string(function), 15)}  #{first}"
        )
      )

      Enum.each(rest, &print("#{String.duplicate(" ", 33)}#{&1}"))
    end

    recent =
      state.recent_requests
      |> Map.reject(fn {_key, at} -> mono - at > @repeat_window_ms end)
      |> Map.put(key, mono)

    {:noreply, %{state | recent_requests: recent}}
  end

  def handle_info({:activity, _workflow_id, %{type: :api_result} = result}, state) do
    print(
      "#{wall(result.wall_us)}  → #{String.pad_trailing(Atom.to_string(result.function), 15)}  #{result.detail}"
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Formatting

  defp commit_line(%{index: index, hash: hash, event: event} = commit) do
    Enum.join(
      [
        wall(System.os_time(:microsecond)),
        String.pad_trailing("WAL ##{index}", 8),
        hash,
        String.pad_trailing(event_name(event), 26),
        String.pad_trailing(owner(event, commit), 17),
        truncate(detail(event, commit))
      ],
      "  "
    )
    |> String.trim_trailing()
  end

  # Which task an event belongs to. A workflow resumed from before this
  # process started has no WorkflowCreated here, so it shows as itself.
  defp owner(%Event.TaskCreated{task_id: task_id}, _commit), do: "task " <> short(task_id)

  defp owner(%{workflow_id: workflow_id}, %{task_id: task_id}) do
    case task_id do
      nil -> "workflow " <> short(workflow_id)
      task_id -> "task " <> short(task_id)
    end
  end

  defp owner(_event, _commit), do: ""

  defp detail(%Event.TaskCreated{mode: mode, input: input}, _commit),
    do: "#{mode} · #{inspect(input)}"

  defp detail(%Event.WorkflowCreated{workflow_id: workflow_id}, _commit),
    do: "workflow " <> short(workflow_id)

  defp detail(%Event.ProposalProduced{proposal: nil}, _commit), do: "no proposal"

  defp detail(%Event.ProposalProduced{proposal: proposal}, %{producing: producing, at: at}) do
    count = length(proposal.intents)

    Enum.join(
      [
        "proposal " <> short(proposal.id),
        "#{count} #{if count == 1, do: "intent", else: "intents"}"
        | since("model", producing, at)
      ],
      " · "
    )
  end

  defp detail(%Event.ProposalProductionFailed{error: error}, %{producing: producing, at: at}),
    do:
      Enum.join(
        [
          ProposalProductionError.message(error)
          | since("after", producing, at)
        ],
        " · "
      )

  defp detail(
         %Event.ProposalValidationFailed{error: %ValidationError{reason: reason}},
         _commit
       ),
       do: reason

  defp detail(%Event.EffectApplied{intent: intent}, _commit), do: intent_name(intent)

  defp detail(%Event.EffectFailed{intent: intent, reason: reason}, _commit),
    do: "#{intent_name(intent)}: #{text(reason)}"

  defp detail(%Event.WorkflowCompleted{}, commit),
    do: Enum.join(["completed" | total(commit)], " · ")

  defp detail(%Event.WorkflowFailed{reason: reason}, commit),
    do: Enum.join([text(reason) | total(commit)], " · ")

  defp detail(%Event.WorkflowAbandoned{reason: reason}, commit),
    do: Enum.join([text(reason) | total(commit)], " · ")

  defp detail(%Event.ModeInvalid{mode: mode}, _commit), do: inspect(mode)
  defp detail(_event, _commit), do: ""

  defp total(%{task_started: started, at: at}), do: since("total", started, at)

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

  # Local time with milliseconds, like Logger's console output.
  defp wall(us) do
    {_date, {h, m, sec}} = :calendar.system_time_to_local_time(us, :microsecond)
    ms = us |> div(1000) |> rem(1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, sec, ms]) |> IO.iodata_to_binary()
  end

  ## What the model asked to see

  defp observe_lines(%{type: :requested, entries: entries} = item) do
    count = length(entries)
    [observe_line(item, "asked to see #{count} #{if count == 1, do: "thing", else: "things"}")]
  end

  defp observe_lines(%{type: :settled, round: round, entries: entries} = item) do
    Enum.map(entries, &observe_line(round, item, settled_text(&1)))
  end

  defp observe_line(item, text), do: observe_line(item.round, item, text)

  defp observe_line(round, item, text) do
    owner = if item.task_id, do: "task " <> short(item.task_id), else: ""

    Enum.join(
      [
        wall(System.os_time(:microsecond)),
        String.pad_trailing("observe round #{round}", 17),
        String.pad_trailing(owner, 17),
        text
      ],
      "  "
    )
    |> String.trim_trailing()
  end

  defp settled_text(%{status: :shown, label: label, bytes: bytes}),
    do: truncate("✓ #{label} · #{size(bytes)}")

  defp settled_text(%{status: :refused, label: label, error: error}),
    do: truncate("✗ #{label} · #{error}")

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes), do: "#{:erlang.float_to_binary(bytes / 1024, decimals: 1)} KB"
end
