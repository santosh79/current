defmodule Current.TestApproval do
  @moduledoc """
  Approving and applying are separate steps, and a test that wants a
  proposal's effects applied has to take both. The second must wait for
  the first to be projected: `Current.review_proposal/2` returns once
  ProposalApproved is proposed, not once WorkflowStore reflects it.
  """

  alias Current.{ProposalStore, WorkflowStore}

  @doc "Approves `proposal_id`, waits until its workflow is :approved, then applies it."
  @spec approve_and_apply(Current.Id.t(), map()) :: :ok | {:error, term()}
  def approve_and_apply(proposal_id, metadata \\ %{reviewed_by: :test}) do
    with :ok <- Current.review_proposal(proposal_id, {:approve, metadata}),
         :ok <- await_status(proposal_id, :approved) do
      Current.apply_proposal(proposal_id)
    end
  end

  @doc "Waits (up to ~5s) until the proposal's workflow has `status`."
  @spec await_status(Current.Id.t(), Current.Workflow.status(), non_neg_integer()) ::
          :ok | {:error, {:status, Current.Workflow.status()}}
  def await_status(proposal_id, status, attempts \\ 500) do
    {:ok, proposal} = ProposalStore.get(proposal_id)
    {:ok, workflow} = WorkflowStore.get(proposal.workflow_id)

    cond do
      workflow.status == status ->
        :ok

      attempts == 0 ->
        {:error, {:status, workflow.status}}

      true ->
        Process.sleep(10)
        await_status(proposal_id, status, attempts - 1)
    end
  end
end
