defmodule Current.ProposalFiles do
  @moduledoc """
  Best-effort developer snapshots of committed proposals.

  The cursor is an EventStore log position. It is intentionally not persisted:
  restarting walks the history again, and deterministic, idempotent writes make
  that safe.
  """

  use GenServer

  alias Current.{Inspector, Proposal, ProposalStore, TaskStore, Workflow, WorkflowStore}
  alias Current.CLI.{ReviewJSON, ReviewMarkdown}

  @default_interval_ms 20_000
  @default_batch_size 100
  @max_slug_length 40

  @type state :: %{
          cursor: non_neg_integer(),
          dir: Path.t(),
          interval_ms: pos_integer(),
          batch_size: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      cursor: 0,
      dir: Keyword.get_lazy(opts, :dir, &default_dir/0),
      interval_ms:
        Keyword.get_lazy(opts, :interval_ms, fn ->
          Application.get_env(:current, :proposal_files_interval_ms, @default_interval_ms)
        end),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size)
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state) do
    {:noreply, tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, tick(state)}
  end

  @doc "Builds the safe, deterministic slug used in a workflow directory name."
  @spec slug(term()) :: String.t()
  def slug(input) when is_binary(input) do
    input
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}+/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> truncate_slug()
    |> fallback_slug()
  end

  def slug(_input), do: "task"

  @doc "Builds a workflow's deterministic proposal directory name."
  @spec directory_name(Workflow.t(), term()) :: String.t()
  def directory_name(%Workflow{} = workflow, input) do
    timestamp =
      workflow.created_at
      |> DateTime.shift_zone!("Etc/UTC")
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    "#{timestamp}-#{slug(input)}-#{short_id(workflow.id)}"
  end

  @doc "Builds a proposal's deterministic Markdown file name."
  @spec file_name(Proposal.t()) :: String.t()
  def file_name(%Proposal{} = proposal) do
    "r#{proposal.revision}-#{short_id(proposal.id)}.md"
  end

  @doc "Renders the immutable produced-proposal snapshot written to disk."
  @spec render_snapshot(Current.Id.t()) :: String.t()
  def render_snapshot(proposal_id) do
    {:ok, review} = Inspector.review(proposal_id, %{max_lines: 2_000})

    review
    |> ReviewJSON.to_map()
    |> immutable_document()
    |> ReviewMarkdown.render()
  end

  defp tick(state) do
    state = drain(state)
    Process.send_after(self(), :tick, state.interval_ms)
    state
  end

  defp drain(state) do
    rows = ProposalStore.produced_after(state.cursor, state.batch_size)

    state =
      Enum.reduce(rows, state, fn {position, proposal_id}, state ->
        write_proposal(state.dir, proposal_id)
        %{state | cursor: position}
      end)

    if length(rows) == state.batch_size, do: drain(state), else: state
  end

  defp write_proposal(root, proposal_id) do
    {:ok, proposal} = ProposalStore.get(proposal_id)
    {:ok, workflow} = WorkflowStore.get(proposal.workflow_id)
    {:ok, task} = TaskStore.get(workflow.task_id)

    dir = Path.join(root, directory_name(workflow, task.input))
    path = Path.join(dir, file_name(proposal))
    contents = render_snapshot(proposal_id)

    case File.read(path) do
      {:ok, ^contents} ->
        :ok

      _ ->
        File.mkdir_p!(dir)
        temporary = path <> ".tmp"
        File.write!(temporary, contents)
        File.rename!(temporary, path)
    end
  end

  defp immutable_document(document) do
    document
    |> Map.drop([
      "current_proposal_id",
      "revisions_remaining",
      "validation_error"
    ])
    |> update_in(["workflow"], &Map.delete(&1, "status"))
  end

  defp truncate_slug(value) do
    if String.length(value) <= @max_slug_length do
      value
    else
      prefix = String.slice(value, 0, @max_slug_length)

      cond do
        String.at(value, @max_slug_length) == "-" -> prefix
        String.ends_with?(prefix, "-") -> String.trim_trailing(prefix, "-")
        String.contains?(prefix, "-") ->
          prefix
          |> String.split("-")
          |> Enum.drop(-1)
          |> Enum.join("-")

        true ->
          prefix
      end
    end
  end

  defp fallback_slug(""), do: "task"
  defp fallback_slug(value), do: value

  defp short_id("sha256:" <> hex), do: String.slice(hex, 0, 8)

  defp default_dir do
    :current
    |> Application.fetch_env!(:data_dir)
    |> Path.expand()
    |> Path.join("proposals")
  end
end
