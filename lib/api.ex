defmodule Current.API do
  @moduledoc """
  The Current runtime's public control-plane API: the only module the
  HTTP layer (`Current.HTTP.Router`) calls. Every client -- the `current`
  CLI, an IDE plugin, a TUI, a script -- reaches the runtime over HTTP.

  Everything is request/response and returns plain data. No function
  takes a client pid or pushes messages to a client, so a client holds
  no runtime state, can disconnect at any time, and can pick a workflow
  up again later by id. Canonical state stays in the runtime's committed
  history.

  Keeping this surface explicit is the point: the HTTP routes depend on
  these functions, not on EventStore, WorkflowStore or BlobStore, which
  stay free to change behind it.
  """

  alias Current.{ActivityHub, Inspector, Request, WorkflowStore}

  @doc """
  Submits a task and returns its id straight away. The workflow is
  created asynchronously once TaskCreated commits, so poll `workflow/1`
  with the task id (it resolves task ids to their workflow).

  `request.model` is required: one entry of `models/0`, e.g.
  `"anthropic:claude-opus-5-5"`. The runtime checks it against its
  catalog before anything is recorded, and answers
  `{:error, {:unknown_model, model}}` for one that isn't listed.

  `project_dir` should be absolute: a relative one would resolve
  against the runtime's working directory, not the client's.
  """
  @spec submit_task(Request.t(), Path.t()) ::
          {:ok, Current.Id.t()} | {:error, {:unknown_model, String.t()}} | {:error, term()}
  def submit_task(%Request{} = request, project_dir) when is_binary(project_dir) do
    ActivityHub.api(:submit_task, [
      "#{request.mode} #{preview(request.input)}",
      clip(project_dir),
      "model #{clip(request.model)}"
    ])

    # submit_task/3 wants a listener pid. This call's process exits as
    # soon as it returns (the router calls from a short-lived task), so
    # notifications sent to it are dropped -- clients learn about progress
    # by polling, never by messages.
    result = Current.submit_task(request, self(), project_dir)

    ActivityHub.api_result(
      :submit_task,
      case result do
        {:ok, "sha256:" <> hex} ->
          "accepted as task " <> binary_part(hex, 0, 12)

        {:ok, task_id} ->
          "accepted as task #{task_id}"

        {:error, {:unknown_model, unknown}} ->
          "✗ rejected: unknown model #{String.slice(unknown, 0, 100)}"

        {:error, {:too_large, field, size, max}} ->
          "✗ rejected: #{field} is #{size} bytes (limit #{max})"

        {:error, {:invalid_project_dir, path, reason}} ->
          "✗ rejected: #{path} (#{reason})"

        {:error, reason} ->
          "✗ failed: #{inspect(reason)}"
      end
    )

    result
  end

  @doc """
  `submit_task/2`, run in a short-lived process of its own, for callers
  whose process lives on (an MCP request, a long-lived connection).

  `submit_task/2` registers its calling process as the task's listener,
  and notifications for the task go to that pid. Run from a worker that
  exits as soon as it has answered, they are dropped, and nothing from
  the task ever reaches the caller's mailbox. Clients follow progress by
  polling.

  The worker is monitored, not linked, so its crash can't take the caller
  down. It sends exactly one tagged result message. The caller accepts
  either order of that message and the monitor's `:DOWN`, so it does not
  depend on which arrives first.

  Returns what `submit_task/2` returns, or `{:error, :submit_timeout}` if
  there is no answer within `timeout_ms` (the worker is then killed), or
  `{:error, {:submit_crashed, reason}}` if the worker died without one.
  """
  @spec submit_task_isolated(Request.t(), Path.t(), timeout()) ::
          {:ok, Current.Id.t()}
          | {:error, :submit_timeout}
          | {:error, {:submit_crashed, term()}}
          | {:error, term()}
  def submit_task_isolated(%Request{} = request, project_dir, timeout_ms \\ 30_000)
      when is_binary(project_dir) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {tag, submit_task(request, project_dir)}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        # The result may already be in the mailbox behind the :DOWN.
        receive do
          {^tag, result} -> result
        after
          0 -> {:error, {:submit_crashed, reason}}
        end
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        # It may have answered just as the timeout fired.
        receive do
          {^tag, _result} -> :ok
        after
          0 -> :ok
        end

        {:error, :submit_timeout}
    end
  end

  @doc """
  Approves a proposal, by full id or unique prefix, and returns the id
  of its workflow.

  Approval makes the proposal eligible to be applied; it applies
  nothing. The workflow parks in `:approved` until `apply_proposal/1`.

  Only proposals from `:apply` workflows can be reviewed. A `:plan`
  workflow never applies anything, so its proposals are refused here
  with `{:not_apply_mode, mode}` (and WorkflowReducer refuses the
  review at commit time regardless).

  `metadata` is recorded verbatim on ProposalApproved.
  """
  @spec approve(String.t(), map()) ::
          {:ok, Current.Id.t()}
          | {:error, Inspector.lookup_error() | {:not_apply_mode, Current.Mode.t()} | term()}
  def approve(proposal_id, metadata) when is_binary(proposal_id) and is_map(metadata) do
    logged(:approve, proposal_id, "approved", fn ref ->
      with :ok <- Current.review_proposal(ref.proposal_id, {:approve, metadata}) do
        await_reviewed(ref.workflow_id)
      end
    end)
  end

  @doc """
  Rejects a proposal, by full id or unique prefix, and returns the id of
  its workflow. Only a proposal waiting for approval can be rejected.
  `metadata` is recorded verbatim on ProposalRejected.
  """
  @spec reject(String.t(), map()) ::
          {:ok, Current.Id.t()}
          | {:error, Inspector.lookup_error() | {:not_apply_mode, Current.Mode.t()} | term()}
  def reject(proposal_id, metadata) when is_binary(proposal_id) and is_map(metadata) do
    logged(:reject, proposal_id, "rejected", fn ref ->
      with :ok <- Current.review_proposal(ref.proposal_id, {:reject, metadata}) do
        await_reviewed(ref.workflow_id)
      end
    end)
  end

  @doc """
  Sends a proposal back for a new one, by full id or unique prefix, and
  returns the id of its workflow so the caller can follow it.

  `feedback` is what the reviewer wants changed; it reaches the proposal
  builder verbatim. The proposal must be the workflow's most recent, and
  the workflow must have revisions left; WorkflowReducer decides both and
  its errors (`{:stale_proposal, given, current}`,
  `{:revision_limit_reached, max}`) come back here unchanged.

  `metadata` is recorded verbatim on ProposalRevisionRequested.
  """
  @spec request_revision(String.t(), String.t(), map()) ::
          {:ok, Current.Id.t()}
          | {:error, Inspector.lookup_error() | {:not_apply_mode, Current.Mode.t()} | term()}
  def request_revision(proposal_id, feedback, metadata)
      when is_binary(proposal_id) and is_binary(feedback) and is_map(metadata) do
    logged(:request_revision, proposal_id, "revision requested", fn ref ->
      with :ok <- Current.request_revision(ref.proposal_id, feedback, metadata) do
        await_reviewed(ref.workflow_id)
      end
    end)
  end

  @doc """
  Starts applying an approved proposal, by full id or unique prefix, and
  returns the id of its workflow so the caller can follow it. See
  Current.apply_proposal/1.
  """
  @spec apply_proposal(String.t()) ::
          {:ok, Current.Id.t()}
          | {:error, Inspector.lookup_error() | {:not_apply_mode, Current.Mode.t()} | term()}
  def apply_proposal(proposal_id) when is_binary(proposal_id) do
    logged(:apply_proposal, proposal_id, "applying", fn ref ->
      Current.apply_proposal(ref.proposal_id)
    end)
  end

  # A review is committed when review_proposal/2 returns but projected
  # asynchronously. Waiting (briefly) for the projection to move on means
  # that once approve returns, an apply that follows straight away -- as
  # in `current approve X && current apply X` -- sees the approval.
  defp await_reviewed(workflow_id, attempts \\ 200) do
    case WorkflowStore.get(workflow_id) do
      {:ok, %{status: :waiting_for_approval}} when attempts > 0 ->
        Process.sleep(10)
        await_reviewed(workflow_id, attempts - 1)

      _ ->
        :ok
    end
  end

  # Resolves the proposal, requires an :apply workflow, runs `fun`, and
  # records the request and its outcome in the activity log.
  defp logged(function, proposal_id, ok_text, fun) do
    ActivityHub.api(function, [clip(proposal_id)])

    result =
      with {:ok, ref} <- Inspector.resolve_proposal(proposal_id),
           :ok <- require_apply_mode(ref.mode),
           :ok <- fun.(ref) do
        {:ok, ref.workflow_id}
      end

    ActivityHub.api_result(
      function,
      case result do
        {:ok, _workflow_id} -> ok_text
        {:error, reason} -> "✗ #{inspect(reason)}"
        other -> "✗ #{inspect(other)}"
      end
    )

    result
  end

  defp require_apply_mode(:apply), do: :ok
  defp require_apply_mode(mode), do: {:error, {:not_apply_mode, mode}}

  @doc "A workflow's canonical history and status, by workflow id, task id or unique prefix."
  @spec workflow(String.t()) ::
          {:ok, Inspector.workflow_view()} | {:error, Inspector.lookup_error()}
  def workflow(id) do
    ActivityHub.api(:workflow, [clip(id)])
    Inspector.workflow(id)
  end

  @doc "A proposal, where it came from and what became of it."
  @spec proposal(String.t()) ::
          {:ok, Inspector.proposal_view()} | {:error, Inspector.lookup_error()}
  def proposal(id) do
    ActivityHub.api(:proposal, [clip(id)])
    Inspector.proposal(id)
  end

  @doc """
  A proposal with its artifacts' contents, each cut to `:max_lines`
  lines; see Current.Inspector.review/2.
  """
  @spec review(String.t(), Inspector.review_opts()) ::
          {:ok, Inspector.review_view()} | {:error, Inspector.lookup_error()}
  def review(id, opts) when is_binary(id) and is_map(opts) do
    ActivityHub.api(:review, [clip(id)])
    Inspector.review(id, opts)
  end

  @doc "An artifact's full id and exact bytes."
  @spec artifact(String.t()) :: {:ok, Current.Id.t(), binary()} | {:error, term()}
  def artifact(id) do
    ActivityHub.api(:artifact, [clip(id)])
    Inspector.artifact(id)
  end

  @doc """
  What the model has asked to see, and been shown, while the workflow
  `workflow_id` (a full id, as `workflow/1` returns it) works out its
  proposal -- live, for showing progress. `epoch` and `after_seq` are the
  `epoch` and `last_seq` of the previous answer (nil and 0 the first time);
  only newer items come back. A different epoch means the runtime's
  activity view restarted, and everything it has is returned.

  This is a view of what is happening, not a record: nothing here is
  durable, and a workflow the runtime has no activity for -- finished long
  ago, or from before a restart -- simply has none. What a model looked at
  is recorded with its proposal (see `proposal/1`). Polling this is not
  itself logged to the console.
  """
  @spec activity(String.t(), integer() | nil, non_neg_integer()) :: %{
          epoch: integer(),
          items: [map()],
          last_seq: non_neg_integer()
        }
  def activity(workflow_id, epoch \\ nil, after_seq \\ 0)
      when is_binary(workflow_id) and is_integer(after_seq) do
    ActivityHub.activity(workflow_id, epoch, after_seq)
  end

  @doc "Whether the runtime is up, and what it is configured to use."
  @spec health() :: map()
  def health do
    ActivityHub.api(:health)
    status()
  end

  @doc "Returns the current model snapshot."
  @spec models() :: [String.t()]
  def models do
    ActivityHub.api(:models)
    {:ok, pid} = Current.ModelCatalog.find_supervisor_pid()
    Current.ModelCatalog.all(pid)
  end

  @doc false
  # health/0 without the request being logged, for the server's banner.
  def status do
    %{
      status: :ready,
      node: node(),
      version: version(),
      # The WAL's own head commit index -- not EventStore's position,
      # which drifts from it once a commit is rejected or holds several
      # events.
      wal_head: wal_head(),
      wal_path: Current.Consensus.Log.path(),
      proposal_builder: Application.get_env(:current, :proposal_builder),
      allowed_commands: Application.get_env(:current, :allowed_commands, []),
      # One model call, and one task's whole proposal (several calls).
      llm_proposal_timeout_ms: Application.get_env(:current, :llm_proposal_timeout_ms),
      llm_task_timeout_ms: Current.LLMProposalBuilder.task_timeout_ms()
    }
  end

  defp wal_head do
    case Current.Consensus.Log.head() do
      {:ok, commit} -> commit.index
      :empty -> 0
    end
  end

  # Anything a caller supplies is cut before it is logged, so a huge id or
  # path can't flood the activity log (the value itself is validated, and
  # refused if need be, later by the runtime).
  defp clip(value, max \\ 100)

  defp clip(value, max) when is_binary(value) do
    case String.split_at(value, max) do
      {head, ""} -> head
      {head, _rest} -> head <> "…"
    end
  end

  defp clip(value, max), do: value |> inspect(limit: 5, printable_limit: max) |> clip(max)

  defp preview(input) do
    text = inspect(input, limit: 20, printable_limit: 200)
    if String.length(text) > 200, do: String.slice(text, 0, 200) <> "…", else: text
  end

  defp version do
    case Application.spec(:current, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
