defmodule Current.CLI do
  @moduledoc """
  The `current` command-line interface (built as an escript).

      current plan <prompt> --model <model> [--dir <project-dir>] [--timeout-minutes <n>]
      current run <prompt> --model <model> [--dir <project-dir>] [--timeout-minutes <n>]
      current approve <proposal-id> [--message <message>]
      current reject <proposal-id> [--message <message>]
      current apply <proposal-id>
      current events <workflow-id>
      current proposal <proposal-id>
      current review <proposal-id> [--json] [--max-lines <n>] [--raw]
      current artifact <artifact-id>
      current models
      current status

  Current is the runtime; `current` is merely a client of it. The CLI
  boots nothing and knows nothing about which models exist: every
  command is a request to the runtime's HTTP API (see
  `Current.CLI.Client`, `Current.HTTP.Router` and `bin/current-server`).

  `--model` is required on plan and run. It names the model for that one
  task, as `current models` prints it (e.g. `openai:gpt-5.6`). The CLI
  passes it on untouched; the runtime checks it against its catalog and
  refuses the task if it isn't listed. There is no default model.

  `plan` submits the task, then polls the workflow's canonical projection
  until it is terminal. `run` does the same in apply mode, but stops
  polling once the proposal is waiting for approval.

  Approving and applying are separate steps. `approve` records that the
  proposal is authorized and returns; the workflow parks in `approved`
  and nothing is applied. `apply` starts applying an approved proposal
  and follows the workflow to its end. `reject` ends a proposal that is
  waiting for approval.

  The CLI holds no runtime state, so it can be interrupted at
  any point; the workflow carries on, and `current events <task-id>`
  picks it up again.

  Ids may be shortened to any unique prefix of 4+ hex digits, with or
  without the `sha256:` part.

  `run/2` takes the connection as an argument and returns an exit code,
  so tests drive it against the test application in-process (the client
  then calls the router directly, without a socket).
  """

  alias Current.CLI.{Client, Render, ReviewJSON, ReviewMarkdown}

  @exit_ok 0
  @exit_failed 1
  @exit_usage 2

  @poll_ms 250
  # Give up waiting after the runtime's bound on producing a proposal
  # plus this much time without any new event.
  @idle_slack_ms 60_000
  @default_model_timeout_ms 120_000

  @default_approval_message "Approved via the current CLI"
  @default_rejection_message "Rejected via the current CLI"
  @default_review_max_lines 200

  # The longest --timeout-minutes accepted (the runtime enforces the same bound).
  @max_timeout_minutes 60

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

      # A usage error with a specific way out: say that, not the whole usage.
      {:error, message, hint} ->
        IO.puts(:stderr, "current: #{message}\n#{hint}")
        @exit_usage

      command ->
        case connect.() do
          {:ok, client} -> dispatch(command, client)
          {:error, reason} -> fail(transport_error(reason, Client.base_url()))
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

      ["models"] ->
        :models

      ["status"] ->
        :status

      ["plan" | rest] ->
        parse_task(:plan, rest)

      ["run" | rest] ->
        parse_task(:run, rest)

      ["approve" | rest] ->
        parse_decision(:approve, @default_approval_message, rest)

      ["reject" | rest] ->
        parse_decision(:reject, @default_rejection_message, rest)

      ["apply" | rest] ->
        parse_apply(rest)

      ["review" | rest] ->
        parse_review(rest)

      [command | rest] when command in ["events", "proposal", "artifact"] ->
        parse_id(command, rest)

      [command | _] ->
        {:error, "unknown command #{inspect(command)}"}
    end
  end

  @models_hint "List the available models with:  current models"

  # plan and run take the same arguments; only the mode differs.
  # --model is required; without one, point at `current models` rather
  # than repeating the whole usage.
  defp parse_task(command, args) do
    case OptionParser.parse(args,
           strict: [dir: :string, model: :string, timeout_minutes: :integer, help: :boolean],
           aliases: [d: :dir, h: :help]
         ) do
      {opts, argv, []} ->
        prompt = argv |> Enum.join(" ") |> String.trim()
        dir = Keyword.get(opts, :dir, ".")
        model = opts |> Keyword.get(:model, "") |> String.trim()
        minutes = Keyword.get(opts, :timeout_minutes)

        cond do
          opts[:help] ->
            :help

          prompt == "" ->
            {:error, "#{command} needs a prompt"}

          not Keyword.has_key?(opts, :model) ->
            {:error, "#{command} needs --model <model>", @models_hint}

          model == "" ->
            {:error, "#{command}: --model can't be blank", @models_hint}

          minutes != nil and minutes not in 1..@max_timeout_minutes ->
            {:error,
             "#{command}: --timeout-minutes must be a whole number from 1 to " <>
               "#{@max_timeout_minutes}"}

          true ->
            {command, prompt, dir, model, minutes && minutes * 60_000}
        end

      {_opts, _argv, [{flag, _value} | _]} ->
        {:error, "invalid option #{flag}"}
    end
  end

  # approve and reject: a proposal id and an optional message.
  defp parse_decision(command, default_message, args) do
    case OptionParser.parse(args,
           strict: [message: :string, help: :boolean],
           aliases: [m: :message, h: :help]
         ) do
      {opts, argv, []} ->
        message = Keyword.get(opts, :message, default_message)

        cond do
          opts[:help] -> :help
          String.trim(message) == "" -> {:error, "#{command}: --message can't be blank"}
          argv == [] -> {:error, "#{command} needs a proposal id"}
          length(argv) > 1 -> {:error, "#{command} takes exactly one proposal id"}
          true -> {command, String.trim(hd(argv)), message}
        end

      {_opts, _argv, [{flag, _value} | _]} ->
        {:error, "invalid option #{flag}"}
    end
  end

  defp parse_apply(args) do
    case OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help]) do
      {opts, argv, []} ->
        cond do
          opts[:help] -> :help
          argv == [] -> {:error, "apply needs a proposal id"}
          length(argv) > 1 -> {:error, "apply takes exactly one proposal id"}
          true -> {:apply, String.trim(hd(argv))}
        end

      {_opts, _argv, [{flag, _value} | _]} ->
        {:error, "invalid option #{flag}"}
    end
  end

  defp parse_review(args) do
    case OptionParser.parse(args,
           strict: [json: :boolean, max_lines: :integer, raw: :boolean, help: :boolean],
           aliases: [h: :help]
         ) do
      {opts, argv, []} ->
        max_lines = Keyword.get(opts, :max_lines, @default_review_max_lines)

        cond do
          opts[:help] -> :help
          max_lines < 1 -> {:error, "review: --max-lines must be at least 1"}
          argv == [] -> {:error, "review needs a proposal id"}
          length(argv) > 1 -> {:error, "review takes exactly one proposal id"}
          true -> {:review, String.trim(hd(argv)), review_opts(opts, max_lines)}
        end

      {_opts, _argv, [{flag, _value} | _]} ->
        {:error, "invalid option #{flag}"}
    end
  end

  defp review_opts(opts, max_lines) do
    %{
      format: if(opts[:json], do: :json, else: :markdown),
      max_lines: max_lines,
      raw: Keyword.get(opts, :raw, false)
    }
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
      current plan <prompt> --model <model> [--dir <project-dir>] [--timeout-minutes <n>]
      current run <prompt> --model <model> [--dir <project-dir>] [--timeout-minutes <n>]
      current approve <proposal-id> [--message <message>]
      current reject <proposal-id> [--message <message>]
      current apply <proposal-id>
      current events <workflow-id>
      current proposal <proposal-id>
      current review <proposal-id> [--json] [--max-lines <n>] [--raw]
      current artifact <artifact-id>
      current models
      current status

    Commands:
      plan      Ask the agent for a proposal and validate it. Nothing is executed.
      run       Like plan, but in apply mode: stops for approval. Nothing is executed yet.
      approve   Authorize a proposal from run. Nothing is applied yet.
      reject    Turn down a proposal from run.
      apply     Apply an approved proposal, and follow it to the end.
      events    A workflow's canonical event history (a task id works too).
      proposal  A proposal in full: intents, claims, artifacts.
      review    A proposal with its diffs and file contents, as Markdown (or --json).
      artifact  An artifact's exact bytes, e.g. a proposed diff.
      models    Models currently discovered from configured LLM providers.
      status    Whether the runtime is up, and how it is configured.

    Options:
      -d, --dir      Project directory for plan and run (default: the current directory)
      --model        Model for plan and run (required), as listed by
                     `current models`, e.g. openai:gpt-5.6
      --timeout-minutes
                     plan and run: how long the agent may take to produce its
                     proposal, 1 to 60 (default: the runtime's own bound)
      -m, --message  Message recorded by approve or reject
      --json         review: machine-readable output (schema current.review/v1)
      --max-lines    review: lines shown per artifact (default: #{@default_review_max_lines})
      --raw          review: include the model's raw output
      -h, --help     Show this help

    Ids can be shortened to a unique prefix (4+ hex digits).

    The runtime must be running (bin/current-server).
    Environment:
      CURRENT_URL     The runtime's HTTP API (default: http://127.0.0.1:4000)
    """
    |> String.trim_trailing()
  end

  ## Commands

  defp dispatch(:status, client) do
    case Client.health(client) do
      {:ok, health} -> print(Render.status(health, client.url))
      {:error, reason} -> fail(transport_error(reason, client.url))
    end
  end

  defp dispatch({:plan, prompt, dir, model, timeout_ms}, client),
    do: submit(:plan, prompt, dir, model, timeout_ms, client)

  defp dispatch({:run, prompt, dir, model, timeout_ms}, client),
    do: submit(:apply, prompt, dir, model, timeout_ms, client)

  defp dispatch({:approve, id, message}, client) do
    case Client.approve(client, id, review_metadata(message)) do
      {:ok, _workflow_id} ->
        print(
          "✓ Approved #{id}\n  message  #{message}\n\n" <>
            "Nothing has been applied. Apply it with:\n  current apply #{id}"
        )

      {:error, reason} ->
        fail(review_error(:approve, id, reason, client))
    end
  end

  defp dispatch({:reject, id, message}, client) do
    case Client.reject(client, id, review_metadata(message)) do
      {:ok, _workflow_id} ->
        print("✓ Rejected #{id}\n  message  #{message}")

      {:error, reason} ->
        fail(review_error(:reject, id, reason, client))
    end
  end

  defp dispatch({:apply, id}, client) do
    with {:ok, health} <- Client.health(client),
         {:ok, workflow_id} <- Client.apply_proposal(client, id) do
      IO.puts("✓ Applying #{id}\n")

      # ProposalProductionStarted is long past: don't announce the model.
      follow(client, workflow_id, health,
        done?: & &1["terminal"],
        expect: "completed",
        started?: true
      )
    else
      {:error, reason} -> fail(apply_error(id, reason, client))
    end
  end

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

  defp dispatch({:review, id, opts}, client) do
    case Client.review(client, id, Map.take(opts, [:max_lines, :raw])) do
      {:ok, review} when opts.format == :json -> print(ReviewJSON.pretty(review))
      {:ok, review} -> print(ReviewMarkdown.render(review))
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

  defp dispatch(:models, client) do
    case Client.models(client) do
      {:ok, models} -> print_models(models)
      {:error, reason} -> fail(transport_error(reason, client.url))
    end
  end

  ## plan and run

  # plan (mode :plan) runs to completion; run (mode :apply) stops once
  # the proposal is waiting for approval -- the runtime itself goes no
  # further until `current approve` and then `current apply`.
  defp submit(mode, prompt, dir, model, timeout_ms, client) do
    params = %{
      prompt: prompt,
      model: model,
      mode: Atom.to_string(mode),
      timeout_ms: timeout_ms,
      # Relative to where the CLI runs, not the runtime's working
      # directory. absname/1 (unlike expand/1) keeps any "..", so the
      # runtime still applies its own rules to the path as given.
      dir: Path.absname(dir)
    }

    with {:ok, health} <- Client.health(client),
         {:ok, task_id} <- Client.submit_task(client, params) do
      IO.puts("Current #{health["version"]} · #{client.url}\n")
      IO.puts(Render.task_submitted(task_id, mode, model))

      case mode do
        :plan ->
          follow(client, task_id, health,
            done?: & &1["terminal"],
            expect: "planned",
            timeout_ms: timeout_ms
          )

        :apply ->
          follow(client, task_id, health,
            done?: &halted?/1,
            expect: "waiting_for_approval",
            timeout_ms: timeout_ms
          )
      end
    else
      {:error, {:api_error, %{code: "invalid_project_dir", message: message}}} ->
        fail("invalid project directory " <> message)

      {:error, {:api_error, %{code: "unknown_model"}}} ->
        fail("unknown model #{model}\nList the available models with:  current models")

      {:error, {:api_error, %{code: code, message: message}}}
      when code in ["invalid_timeout", "model_required", "bad_request"] ->
        fail(message)

      {:error, reason} ->
        fail(transport_error(reason, client.url))
    end
  end

  defp halted?(view), do: view["terminal"] or view["status"] == "waiting_for_approval"

  ## approve, reject, apply

  defp review_metadata(message), do: %{message: message, reviewed_by: reviewer()}

  defp review_error(command, id, {:api_error, %{code: "not_apply_mode"} = error}, _client),
    do: not_apply_mode(command, id, error.details["mode"])

  defp review_error(command, id, {:api_error, %{code: "invalid_transition"} = error}, _client),
    do:
      "proposal #{id} can't be #{past(command)}: " <>
        "its workflow is #{error.details["status"]}, not waiting for approval"

  defp review_error(_command, id, reason, client),
    do: error_message("proposal", id, reason, client)

  defp apply_error(id, {:api_error, %{code: "not_apply_mode"} = error}, _client),
    do: not_apply_mode(:apply, id, error.details["mode"])

  defp apply_error(
         id,
         {:api_error, %{code: "invalid_transition", details: %{"status" => "waiting_for_approval"}}},
         _client
       ) do
    "proposal #{id} hasn't been approved yet. Approve it first:\n" <>
      "  current approve #{id}"
  end

  defp apply_error(id, {:api_error, %{code: "invalid_transition"} = error}, _client),
    do: "proposal #{id} can't be applied: its workflow is #{error.details["status"]}, not approved"

  defp apply_error(id, reason, client), do: error_message("proposal", id, reason, client)

  defp not_apply_mode(command, id, mode) do
    "proposal #{id} is from a #{mode}-mode workflow; " <>
      "only proposals from `current run` can be #{past(command)}"
  end

  defp past(:approve), do: "approved"
  defp past(:reject), do: "rejected"
  defp past(:apply), do: "applied"

  # Who ran the CLI -- not the runtime's user, which is whoever started
  # the server.
  defp reviewer, do: System.get_env("USER") || System.get_env("USERNAME") || "unknown"

  ## Following a workflow

  # Polls `id` (a task or workflow id) until `done?` holds, renders the
  # outcome, and exits 0 only if the workflow ended in the expected status.
  defp follow(client, id, health, opts) do
    # A task submitted with its own timeout may be quiet for that long.
    idle_ms = (Keyword.get(opts, :timeout_ms) || model_wait_ms(health)) + @idle_slack_ms

    case await(client, id, %{
           seen: 0,
           activity_epoch: nil,
           activity_seq: 0,
           started?: Keyword.get(opts, :started?, false),
           idle_ms: idle_ms,
           last_progress: now(),
           done?: Keyword.fetch!(opts, :done?)
         }) do
      {:ok, view} ->
        IO.puts(Render.outcome(view))
        if view["status"] == Keyword.fetch!(opts, :expect), do: @exit_ok, else: @exit_failed

      {:timeout, _state} ->
        IO.puts("""

        ✗ Stopped waiting: no workflow progress for #{div(idle_ms, 1000)}s.
          The workflow keeps running in the runtime.
          current events #{Render.short(id)}
        """)

        @exit_failed

      {:error, reason} ->
        IO.puts("")

        fail(transport_error(reason, client.url) <> "\n  current events #{Render.short(id)}")
    end
  end

  # Polls the canonical projection until state.done? holds. Before
  # WorkflowCreated commits, a task id doesn't resolve yet (:not_found).
  defp await(client, id, state) do
    case Client.workflow(client, id) do
      {:ok, view} ->
        if state.done?.(view) do
          # What happened since the last poll still gets shown, before
          # the outcome.
          show_activity(state, client, view["workflow_id"])
          {:ok, view}
        else
          view
          |> observe(state)
          |> show_activity(client, view["workflow_id"])
          |> retry(client, id)
        end

      {:error, {:api_error, %{code: "not_found"}}} ->
        retry(state, client, id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe(view, state) do
    started? =
      state.started? or
        Enum.any?(view["entries"], &match?(%{"event" => %{"type" => "ProposalProductionStarted"}}, &1))

    if started? and not state.started?, do: IO.puts("  … waiting for the model")

    case length(view["entries"]) do
      count when count > state.seen ->
        %{state | seen: count, started?: started?, last_progress: now()}

      _ ->
        %{state | started?: started?}
    end
  end

  # What the model has asked to see since the last poll, from the runtime's
  # live activity view (not the event log: nothing is committed for it).
  # Each item counts as progress, so a model that takes many rounds to
  # read the project doesn't look stalled. A runtime that can't answer --
  # an older one -- just shows nothing.
  defp show_activity(state, client, workflow_id) do
    case Client.activity(client, workflow_id, state.activity_epoch, state.activity_seq) do
      {:ok, %{"items" => [_ | _] = items, "epoch" => epoch, "last_seq" => last_seq}} ->
        items |> Render.activity() |> Enum.each(&IO.puts/1)
        %{state | activity_epoch: epoch, activity_seq: last_seq, last_progress: now()}

      {:ok, %{"epoch" => epoch, "last_seq" => last_seq}} ->
        %{state | activity_epoch: epoch, activity_seq: last_seq}

      _unavailable ->
        state
    end
  end

  # The longest the runtime can go without committing an event while
  # all is well: producing a proposal, which may take several model
  # calls. A runtime that doesn't report the per-task bound (an older
  # one) is assumed to make a single call.
  defp model_wait_ms(health) do
    health["llm_task_timeout_ms"] || health["llm_proposal_timeout_ms"] ||
      @default_model_timeout_ms
  end

  defp retry(state, client, id) do
    if now() - state.last_progress > state.idle_ms do
      {:timeout, state}
    else
      Process.sleep(@poll_ms)
      await(client, id, state)
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
      do: transport_error(reason, client.url),
      else: Render.lookup_error(kind, id, reason)
  end

  # Failures of the request itself, or of the runtime, as opposed to an
  # answer about the thing asked for ("no such proposal").
  defp transport_error?(:runtime_unavailable), do: true
  defp transport_error?({:http_failed, _}), do: true
  defp transport_error?({:bad_response, _}), do: true
  defp transport_error?({:api_error, %{code: code}}), do: code in ["runtime_error", "internal_error"]
  defp transport_error?(_reason), do: false

  defp transport_error(:runtime_unavailable, url),
    do: "runtime is not running at #{url}\nStart it with:  bin/current-server"

  defp transport_error({:http_failed, :timeout}, url), do: "#{url} did not answer in time"

  defp transport_error({:http_failed, reason}, url),
    do: "request to #{url} failed: #{inspect(reason)}"

  defp transport_error({:bad_response, status}, url),
    do: "#{url} answered with HTTP #{status}, which is not the Current API"

  defp transport_error({:api_error, %{code: code, message: message}}, url)
       when code in ["runtime_error", "internal_error"],
       do: "#{url} reported an error: #{message}"

  defp transport_error({:api_error, %{message: message}}, _url), do: message
  defp transport_error(reason, _url), do: inspect(reason)

  defp print_models([]) do
    IO.puts("No models are currently available.")
    @exit_ok
  end

  defp print_models(models) do
    models
    |> Enum.sort()
    |> Enum.each(&IO.puts/1)

    @exit_ok
  end
end
