defmodule Current.RPC do
  @moduledoc """
  The Current runtime's public control-plane API: the only module a
  client (the `current` CLI today; an IDE plugin, TUI or web gateway
  later) calls on a running node.

  Everything is request/response and returns plain data. No function
  takes a client pid or pushes messages to a client, so a client holds
  no runtime state, can disconnect at any time, and can pick a workflow
  up again later by id. Canonical state stays in the runtime's committed
  history.

  Keeping this surface explicit is the point: clients depend on these
  nine functions, not on EventStore, WorkflowStore or BlobStore, which
  stay free to change behind it.
  """

  alias Current.{ActivityLog, Inspector, Request, WorkflowStore}

  @doc """
  Submits a task and returns its id straight away. The workflow is
  created asynchronously once TaskCreated commits, so poll `workflow/1`
  with the task id (it resolves task ids to their workflow).

  `project_dir` should be absolute: a relative one would resolve
  against the runtime's working directory, not the client's.
  """
  @spec submit_task(Request.t(), Path.t()) :: {:ok, Current.Id.t()} | {:error, term()}
  def submit_task(%Request{} = request, project_dir) when is_binary(project_dir) do
    ActivityLog.rpc(:submit_task, ["#{request.mode} #{inspect(request.input)}", project_dir])

    # submit_task/3 wants a listener pid. This call's process exits as
    # soon as it returns, so notifications sent to it are dropped --
    # clients learn about progress by polling, never by messages.
    result = Current.submit_task(request, self(), project_dir)

    ActivityLog.rpc_result(
      :submit_task,
      case result do
        {:ok, "sha256:" <> hex} -> "accepted as task " <> binary_part(hex, 0, 12)
        {:ok, task_id} -> "accepted as task #{task_id}"
        {:error, {:invalid_project_dir, path, reason}} -> "✗ rejected: #{path} (#{reason})"
        {:error, reason} -> "✗ failed: #{inspect(reason)}"
      end
    )

    result
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
    ActivityLog.rpc(function, [proposal_id])

    result =
      with {:ok, ref} <- Inspector.resolve_proposal(proposal_id),
           :ok <- require_apply_mode(ref.mode),
           :ok <- fun.(ref) do
        {:ok, ref.workflow_id}
      end

    ActivityLog.rpc_result(
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
    ActivityLog.rpc(:workflow, [id])
    Inspector.workflow(id)
  end

  @doc "A proposal, where it came from and what became of it."
  @spec proposal(String.t()) ::
          {:ok, Inspector.proposal_view()} | {:error, Inspector.lookup_error()}
  def proposal(id) do
    ActivityLog.rpc(:proposal, [id])
    Inspector.proposal(id)
  end

  @doc """
  A proposal with its artifacts' contents, each cut to `:max_lines`
  lines; see Current.Inspector.review/2.
  """
  @spec review(String.t(), Inspector.review_opts()) ::
          {:ok, Inspector.review_view()} | {:error, Inspector.lookup_error()}
  def review(id, opts) when is_binary(id) and is_map(opts) do
    ActivityLog.rpc(:review, [id])
    Inspector.review(id, opts)
  end

  @doc "An artifact's full id and exact bytes."
  @spec artifact(String.t()) :: {:ok, Current.Id.t(), binary()} | {:error, term()}
  def artifact(id) do
    ActivityLog.rpc(:artifact, [id])
    Inspector.artifact(id)
  end

  @doc "Whether the runtime is up, and what it is configured to use."
  @spec health() :: map()
  def health do
    ActivityLog.rpc(:health)
    status()
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
      llm_client: Application.get_env(:current, :llm_client),
      model: Application.get_env(:current, :openai_model),
      llm_proposal_timeout_ms: Application.get_env(:current, :llm_proposal_timeout_ms)
    }
  end

  defp wal_head do
    case Current.Consensus.Log.head() do
      {:ok, commit} -> commit.index
      :empty -> 0
    end
  end

  defp version do
    case Application.spec(:current, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
