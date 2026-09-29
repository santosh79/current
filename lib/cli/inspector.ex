defmodule Current.Inspector do
  @moduledoc """
  Read-only views over Current's projections, for the `current` CLI.

  The CLI calls these over Erlang distribution, so each function returns
  plain data (structs from this code base) and does no formatting;
  rendering is entirely the CLI's job. Nothing here writes.

  Every lookup takes a full id or a unique prefix of one, as git does:
  `sha256:4081ab`, or just `4081ab`. A workflow can also be named by its
  task's id, since that is the id `current plan` prints first.
  """

  alias Current.{
    BlobStore,
    EventStore,
    Excerpt,
    Intent,
    Proposal,
    ProposalStore,
    Task,
    TaskStore,
    Workflow,
    WorkflowStore
  }

  alias Current.Event
  alias Current.EventStore.Entry

  @min_prefix_hex 4

  @review_max_lines 200
  # The whole review's line budget, as a multiple of the per-artifact cap.
  @review_budget_factor 10

  @type lookup_error :: :not_found | :prefix_too_short | {:ambiguous, [Current.Id.t()]}

  @type workflow_view :: %{
          workflow_id: Current.Id.t(),
          status: Current.Workflow.status(),
          terminal: boolean(),
          mode: Current.Mode.t(),
          task: Task.t() | nil,
          entries: [Entry.t()]
        }

  @type proposal_view :: %{
          proposal: Proposal.t(),
          workflow_id: Current.Id.t(),
          status: Current.Workflow.status(),
          mode: Current.Mode.t(),
          project_dir: Path.t() | nil,
          raw_output_blob_id: Current.Id.t() | nil,
          validation_error: Current.Error.ValidationError.t() | nil
        }

  @type review_opts :: %{optional(:max_lines) => pos_integer(), optional(:raw) => boolean()}

  @type review_view :: %{
          proposal: Proposal.t(),
          workflow_id: Current.Id.t(),
          status: Current.Workflow.status(),
          mode: Current.Mode.t(),
          project_dir: Path.t() | nil,
          raw_output_blob_id: Current.Id.t() | nil,
          validation_error: Current.Error.ValidationError.t() | nil,
          artifacts: %{Current.Id.t() => Excerpt.t()},
          raw_output: Excerpt.t() | nil,
          limits: %{max_lines: pos_integer(), max_total_lines: pos_integer()}
        }

  @doc """
  A workflow's canonical history: its TaskCreated entry (recorded before
  the workflow existed, so not in the workflow's own stream) followed by
  every entry in the workflow stream, each with its log position.
  """
  @spec workflow(String.t()) :: {:ok, workflow_view()} | {:error, lookup_error()}
  def workflow(id) do
    with {:ok, workflow} <- resolve_workflow(id) do
      task =
        case TaskStore.get(workflow.task_id) do
          {:ok, task} -> task
          {:error, :not_found} -> nil
        end

      {:ok,
       %{
         workflow_id: workflow.id,
         status: workflow.status,
         terminal: Workflow.terminal?(workflow),
         mode: workflow.mode,
         task: task,
         entries:
           task_created_entries(workflow.task_id) ++
             EventStore.list_entries_by_workflow_id(workflow.id)
       }}
    end
  end

  @doc "A proposal, with where it came from and what became of it."
  @spec proposal(String.t()) :: {:ok, proposal_view()} | {:error, lookup_error()}
  def proposal(id) do
    with {:ok, workflow} <- resolve_proposal_workflow(id),
         {:ok, proposal} <- ProposalStore.get(workflow.proposal.id) do
      events = EventStore.list_by_workflow_id(workflow.id)

      proposal_id = proposal.id

      produced =
        Enum.find(events, &match?(%Event.ProposalProduced{proposal: %{id: ^proposal_id}}, &1))

      failed = Enum.find(events, &match?(%Event.ProposalValidationFailed{}, &1))

      project_dir =
        case TaskStore.get(workflow.task_id) do
          {:ok, task} -> task.project_dir
          {:error, :not_found} -> nil
        end

      {:ok,
       %{
         proposal: proposal,
         workflow_id: workflow.id,
         status: workflow.status,
         mode: workflow.mode,
         project_dir: project_dir,
         raw_output_blob_id: produced && produced.raw_output_blob_id,
         validation_error: failed && failed.error
       }}
    end
  end

  @doc """
  A proposal with the contents of its artifacts -- each FilePatch's diff
  and each WriteFile's contents -- for reviewing it in one place.

  Every artifact is cut to `max_lines` lines (default #{@review_max_lines}),
  and the review as a whole to #{@review_budget_factor}× that; see
  Current.Excerpt for how a cut is reported. With `raw: true` the model's
  raw output is included too, after everything else.
  """
  @spec review(String.t(), review_opts()) :: {:ok, review_view()} | {:error, lookup_error()}
  def review(id, opts \\ %{}) do
    max_lines = Map.get(opts, :max_lines, @review_max_lines)
    max_total_lines = max_lines * @review_budget_factor

    with {:ok, view} <- proposal(id) do
      raw_id = if Map.get(opts, :raw, false), do: view.raw_output_blob_id

      {excerpts, _budget_left} =
        (proposal_artifact_ids(view.proposal) ++ List.wrap(raw_id))
        |> Enum.uniq()
        |> Enum.map_reduce(max_total_lines, fn artifact_id, budget ->
          Excerpt.take(artifact_id, BlobStore.read(artifact_id), max_lines, budget)
        end)

      artifacts = Map.new(excerpts, &{&1.id, &1})

      {:ok,
       Map.merge(view, %{
         artifacts: Map.drop(artifacts, List.wrap(raw_id)),
         raw_output: raw_id && Map.fetch!(artifacts, raw_id),
         limits: %{max_lines: max_lines, max_total_lines: max_total_lines}
       })}
    end
  end

  defp proposal_artifact_ids(%Proposal{intents: intents}) do
    Enum.flat_map(intents, fn
      %Intent.FilePatch{diff_artifact_id: id} -> [id]
      %Intent.WriteFile{contents_artifact_id: id} -> [id]
      _ -> []
    end)
  end

  @doc "An artifact's exact bytes, and its full id."
  @spec artifact(String.t()) ::
          {:ok, Current.Id.t(), binary()} | {:error, lookup_error() | term()}
  def artifact(id) do
    with {:ok, prefix} <- normalize(id),
         {:ok, full_id} <- unique(BlobStore.ids_with_prefix(prefix)),
         {:ok, contents} <- BlobStore.read(full_id) do
      {:ok, full_id, contents}
    end
  end

  @doc """
  Resolves a proposal id or unique prefix to the proposal's full id and
  the id and mode of the workflow it belongs to.
  """
  @spec resolve_proposal(String.t()) ::
          {:ok,
           %{proposal_id: Current.Id.t(), workflow_id: Current.Id.t(), mode: Current.Mode.t()}}
          | {:error, lookup_error()}
  def resolve_proposal(id) do
    with {:ok, workflow} <- resolve_proposal_workflow(id) do
      {:ok, %{proposal_id: workflow.proposal.id, workflow_id: workflow.id, mode: workflow.mode}}
    end
  end

  ## Resolution

  # A full id is looked up directly (this is what `current plan` polls
  # with); only a prefix scans every workflow.
  defp resolve_workflow(id) do
    with {:ok, prefix} <- normalize(id) do
      with {:error, :not_found} <- WorkflowStore.get(prefix),
           {:error, :not_found} <- WorkflowStore.get_by_task_id(prefix) do
        WorkflowStore.all()
        |> Enum.filter(
          &(String.starts_with?(&1.id, prefix) or String.starts_with?(&1.task_id, prefix))
        )
        |> unique(& &1.id)
      end
    end
  end

  defp resolve_proposal_workflow(id) do
    with {:ok, prefix} <- normalize(id) do
      WorkflowStore.all()
      |> Enum.filter(&match?(%{proposal: %Proposal{}}, &1))
      |> Enum.filter(&String.starts_with?(&1.proposal.id, prefix))
      |> unique(& &1.proposal.id)
    end
  end

  # A bare hex prefix is taken to mean "sha256:<hex>".
  defp normalize("sha256:" <> hex = id) do
    cond do
      not String.match?(hex, ~r/\A[0-9a-f]*\z/) -> {:error, :not_found}
      byte_size(hex) < @min_prefix_hex -> {:error, :prefix_too_short}
      true -> {:ok, id}
    end
  end

  defp normalize(id) when is_binary(id), do: normalize("sha256:" <> String.downcase(id))

  defp unique(items, id_of \\ & &1) do
    case items do
      [] -> {:error, :not_found}
      [item] -> {:ok, item}
      many -> {:error, {:ambiguous, many |> Enum.map(id_of) |> Enum.uniq() |> Enum.sort()}}
    end
  end

  # TaskCreated carries a task_id, not a workflow_id, so it isn't in the
  # workflow index. A full scan is fine at this size; an index keyed by
  # task_id is the fix if it ever isn't.
  defp task_created_entries(task_id) do
    {:ok, entries} = EventStore.complete_log_entries()
    Enum.filter(entries, &match?(%Entry{event: %Event.TaskCreated{task_id: ^task_id}}, &1))
  end
end
