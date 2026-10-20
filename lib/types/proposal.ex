defmodule Current.Proposal do
  @enforce_keys [:id, :workflow_id, :intents]
  defstruct [
    :id,
    :workflow_id,
    :intents,
    :justification,
    :claims,
    :dependencies,
    observations: []
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intents: [Current.Intent.t()],
          justification: String.t() | nil,
          claims: [String.t()] | nil,
          dependencies: [String.t()] | nil,
          # What the agent looked at before proposing this, in the order
          # it asked: each thing it requested, why, and either the
          # artifact holding what it was shown or why it was shown
          # nothing. Ids only, never contents. Embedded here the way
          # intents are. Empty for a proposal produced without looking at
          # anything.
          observations: [Current.Observation.t()]
        }

  @doc """
  Every proposal, most recently produced first, each as a map holding the
  `:proposal` together with its `:workflow_id` and the `:input` (the
  user's prompt), `:model`, `:timeout_ms`, `:project_dir` and `:task_id`
  of the task it answers.
  """
  @spec all() :: [map()]
  def all do
    Current.ProposalStore.all()
    |> Enum.map(fn proposal ->
      task_id =
        case Current.WorkflowStore.get(proposal.workflow_id) do
          {:ok, workflow} -> workflow.task_id
          {:error, :not_found} -> nil
        end

      Current.Task.request_details(task_id)
      |> Map.put(:proposal, proposal)
      |> Map.put(:workflow_id, proposal.workflow_id)
    end)
  end

  @doc """
  Brings a proposal read back from an older log up to the current shape.

  Proposals are stored inside events as they were when written, so one
  recorded before a field existed comes back without it. Events that
  carry a proposal call this from their `upcast/2`.
  """
  @spec upcast(map() | nil) :: map() | nil
  def upcast(%{__struct__: __MODULE__} = proposal), do: Map.put_new(proposal, :observations, [])
  def upcast(other), do: other
end
