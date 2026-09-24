defmodule Current.CLI do
  @moduledoc """
  The `current` command-line interface (built as an escript).

      current plan <prompt> [--dir <project-dir>]
      current events <workflow-id>
      current proposal <proposal-id>
      current artifact <artifact-id>
      current status

  Current is the runtime; `current` is merely a client of it. The CLI
  boots nothing and knows nothing about which model Current uses: every
  command is a request/response call to `Current.RPC` on a running node
  (see `Current.CLI.Client` and `bin/current-server`).

  `plan` submits the task, then polls the workflow's canonical projection
  until it is terminal. The CLI holds no runtime state, so it can be
  interrupted at any point; the workflow carries on, and `current events
  <task-id>` picks it up again.

  Ids may be shortened to any unique prefix of 4+ hex digits, with or
  without the `sha256:` part.

  `run/2` takes the connection as an argument and returns an exit code,
  so tests drive it against the test application in-process.
  """

  alias Current.Request
  alias Current.CLI.{Client, Render}

  @exit_ok 0
  @exit_failed 1
  @exit_usage 2

  @poll_ms 250
  # Give up waiting after the runtime's model timeout plus this much
  # time without any new event.
  @idle_slack_ms 60_000
  @default_model_timeout_ms 120_000

  ## Entry points

  @doc "escript entry point."
  @spec main([String.t()]) :: no_return()
  def main(args), do: System.halt(run(args, &Client.connect/0))

  @doc """
  Parses `args`, connects with `connect` if the command needs the
  runtime, runs it and returns a process exit code.
  """
  @spec run([String.t()], (-> {:ok, Client.t()} | {:error, term()})) :: non_neg_integer()
  def run(args, connect \\ &Client.local/0) do
    case parse(args) do
      :help ->
        IO.puts(usage())
        @exit_ok

      {:error, message} ->
        IO.puts(:stderr, "current: #{message}\n\n#{usage()}")
        @exit_usage

      command ->
        case connect.() do
          {:ok, client} -> dispatch(command, client)
          {:error, reason} -> fail(transport_error(reason, Client.target_node()))
        end
    end
  end

  ## Argument parsing

  @doc false
  def parse(args) do
    case args do
      [] ->
        :help

      [flag] when flag in ["-h", "--help", "help"] ->
        :help

      ["status"] ->
        :status

      ["plan" | rest] ->
        parse_plan(rest)

      [command | rest] when command in ["events", "proposal", "artifact"] ->
        parse_id(command, rest)

      [command | _] ->
        {:error, "unknown command #{inspect(command)}"}
    end
  end

  defp parse_plan(args) do
    case OptionParser.parse(args,
           strict: [dir: :string, help: :boolean],
           aliases: [d: :dir, h: :help]
         ) do
      {opts, argv, []} ->
        prompt = argv |> Enum.join(" ") |> String.trim()

        cond do
          opts[:help] -> :help
          prompt == "" -> {:error, "plan needs a prompt"}
          true -> {:plan, prompt, Keyword.get(opts, :dir, ".")}
        end

      {_opts, _argv, [{flag, _value} | _]} ->
        {:error, "invalid option #{flag}"}
    end
  end

  defp parse_id(command, args) do
    case args do
      [flag] when flag in ["-h", "--help"] -> :help
      [id] -> {command_atom(command), String.trim(id)}
      [] -> {:error, "#{command} needs an id"}
      _ -> {:error, "#{command} takes exactly one id"}
    end
  end

  defp command_atom("events"), do: :events
  defp command_atom("proposal"), do: :proposal
  defp command_atom("artifact"), do: :artifact

  defp usage do
    """
    Usage:
      current plan <prompt> [--dir <project-dir>]
      current events <workflow-id>
      current proposal <proposal-id>
      current artifact <artifact-id>
      current status

    Commands:
      plan      Ask the agent for a proposal and validate it. Nothing is executed.
      events    A workflow's canonical event history (a task id works too).
      proposal  A proposal in full: intents, claims, artifacts.
      artifact  An artifact's exact bytes, e.g. a proposed diff.
      status    Whether the runtime is up, and how it is configured.

    Options:
      -d, --dir   Project directory for plan (default: the current directory)
      -h, --help  Show this help

    Ids can be shortened to a unique prefix (4+ hex digits).

    The runtime must be running (bin/current-server).
    Environment:
      CURRENT_NODE    Runtime node (default: current@localhost)
      CURRENT_COOKIE  Erlang cookie (default: ~/.erlang.cookie)
    """
    |> String.trim_trailing()
  end

  ## Commands

  defp dispatch(:status, client) do
    case Client.health(client) do
      {:ok, health} -> print(Render.status(health))
      {:error, reason} -> fail(transport_error(reason, client.node))
    end
  end

  defp dispatch({:plan, prompt, dir}, client), do: plan(prompt, dir, client)

  defp dispatch({:events, id}, client) do
    case Client.workflow(client, id) do
      {:ok, view} -> print(Render.events(view))
      {:error, reason} -> fail(error_message("workflow", id, reason, client))
    end
  end

  defp dispatch({:proposal, id}, client) do
    case Client.proposal(client, id) do
      {:ok, view} -> print(Render.proposal(view))
      {:error, reason} -> fail(error_message("proposal", id, reason, client))
    end
  end

  # The artifact's exact bytes and nothing else, so it can be piped
  # (e.g. into `git apply`).
  defp dispatch({:artifact, id}, client) do
    case Client.artifact(client, id) do
      {:ok, _full_id, contents} ->
        write_raw(contents)
        @exit_ok

      {:error, reason} ->
        fail(error_message("artifact", id, reason, client))
    end
  end

  ## plan

  defp plan(prompt, dir, client) do
    with {:ok, health} <- Client.health(client),
         request = %Request{input: prompt, context: %{}, mode: :plan},
         # Relative to where the CLI runs, not the runtime's working
         # directory. absname/1 (unlike expand/1) keeps any "..", so
         # submit_task/3 still applies its own rules to the path as given.
         {:ok, task_id} <- Client.submit_task(client, request, Path.absname(dir)) do
      IO.puts("Current #{health.version} · #{health.node}\n")
      IO.puts(Render.plan_submitted(task_id))

      idle_ms = (health.llm_proposal_timeout_ms || @default_model_timeout_ms) + @idle_slack_ms

      case await(client, task_id, %{
             seen: 0,
             started?: false,
             idle_ms: idle_ms,
             last_progress: now()
           }) do
        {:ok, view} ->
          IO.puts(Render.plan_outcome(view))
          if match?(%{status: :planned}, view), do: @exit_ok, else: @exit_failed

        {:timeout, _state} ->
          IO.puts("""

          ✗ Stopped waiting: no workflow progress for #{div(idle_ms, 1000)}s.
            The workflow keeps running in the runtime.
            current events #{Render.short(task_id)}
          """)

          @exit_failed

        {:error, reason} ->
          IO.puts("")

          fail(
            transport_error(reason, client.node) <> "\n  current events #{Render.short(task_id)}"
          )
      end
    else
      {:error, {:invalid_project_dir, path, reason}} ->
        fail("invalid project directory #{path} (#{reason})")

      {:error, reason} ->
        fail(transport_error(reason, client.node))
    end
  end

  # Polls the canonical projection until it is terminal. Before
  # WorkflowCreated commits, the task id doesn't resolve yet (:not_found).
  defp await(client, task_id, state) do
    case Client.workflow(client, task_id) do
      {:ok, %{terminal: true} = view} ->
        {:ok, view}

      {:ok, view} ->
        view |> observe(state) |> retry(client, task_id)

      {:error, :not_found} ->
        retry(state, client, task_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe(view, state) do
    started? =
      state.started? or
        Enum.any?(view.entries, &match?(%{event: %Current.Event.ProposalProductionStarted{}}, &1))

    if started? and not state.started?, do: IO.puts("  … waiting for the model")

    case length(view.entries) do
      count when count > state.seen ->
        %{state | seen: count, started?: started?, last_progress: now()}

      _ ->
        %{state | started?: started?}
    end
  end

  defp retry(state, client, task_id) do
    if now() - state.last_progress > state.idle_ms do
      {:timeout, state}
    else
      Process.sleep(@poll_ms)
      await(client, task_id, state)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  ## Output

  defp print(text) do
    IO.puts(text)
    @exit_ok
  end

  defp fail(message) do
    IO.puts(:stderr, "current: " <> message)
    @exit_failed
  end

  # The device is switched to latin1 for the write so bytes pass through
  # untouched instead of being re-encoded.
  defp write_raw(contents) do
    encoding = Keyword.get(:io.getopts(:standard_io), :encoding, :unicode)
    :ok = :io.setopts(:standard_io, encoding: :latin1)

    try do
      IO.binwrite(:standard_io, contents)
    after
      :io.setopts(:standard_io, encoding: encoding)
    end
  end

  defp error_message(kind, id, reason, client) do
    if transport_error?(reason),
      do: transport_error(reason, client.node),
      else: Render.lookup_error(kind, id, reason)
  end

  defp transport_error?(reason) do
    reason == :runtime_unavailable or match?({:rpc_failed, _}, reason) or
      match?({:runtime_raised, _}, reason)
  end

  defp transport_error(:runtime_unavailable, node),
    do: "runtime is not running at #{node}\nStart it with:  bin/current-server"

  defp transport_error({:rpc_failed, :timeout}, node), do: "#{node} did not answer in time"

  defp transport_error({:rpc_failed, reason}, node),
    do: "call to #{node} failed: #{inspect(reason)}"

  defp transport_error({:runtime_raised, message}, node), do: "#{node} raised: #{message}"
  defp transport_error(reason, _node), do: inspect(reason)
end
