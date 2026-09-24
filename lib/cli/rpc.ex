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
  five functions, not on EventStore, WorkflowStore or BlobStore, which
  stay free to change behind it.
  """

  alias Current.{ActivityLog, Inspector, Request}

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
