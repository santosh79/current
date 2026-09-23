defmodule Current.EventSourcingTest do
  @moduledoc """
  End-to-end tests for the event-sourcing invariant.

  For a workflow at rest, the workflow stored in `WorkflowStore` must be
  reproducible by folding that workflow's ordered event stream through
  `Current.WorkflowReducer.replay/1`.
  """

  use ExUnit.Case, async: false

  alias Current.Request

  @receive_timeout 5_000

  defp request(mode \\ :apply) do
    %Request{
      input: "add email validation to signup flow",
      context: %{},
      mode: mode
    }
  end

  defp await(tag, workflow_id \\ nil) do
    receive do
      {^tag, %{workflow_id: event_workflow_id} = event}
      when is_nil(workflow_id) or event_workflow_id == workflow_id ->
        event
    after
      @receive_timeout ->
        flunk("timed out waiting for #{inspect(tag)}")
    end
  end

  defp assert_projection_equals_replay(task_id) do
    assert {:ok, stored} = Current.get_workflow(task_id)
    assert {:ok, replayed} = Current.replay_workflow(stored.id)
    assert replayed == stored
    replayed
  end

  test "replay_workflow returns not_found for an unknown workflow id" do
    unknown = "sha256:" <> String.duplicate("f", 64)

    assert {:error, :not_found} = Current.replay_workflow(unknown)
  end

  test "completed apply workflow projection equals replay" do
    {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

    produced = await(:proposal_produced)
    proposal = produced.proposal
    workflow_id = produced.workflow_id

    await(:proposal_validated, workflow_id)

    assert :ok =
             Current.review_proposal(
               proposal.id,
               {:approve, %{reviewed_by: :event_sourcing_test}}
             )

    await(:workflow_completed, workflow_id)

    replayed = assert_projection_equals_replay(task_id)
    assert replayed.status == :completed
  end

  test "rejected workflow projection equals replay" do
    {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

    produced = await(:proposal_produced)
    proposal = produced.proposal
    workflow_id = produced.workflow_id

    await(:proposal_validated, workflow_id)

    assert :ok =
             Current.review_proposal(
               proposal.id,
               {:reject, %{reviewed_by: :event_sourcing_test}}
             )

    await(:proposal_rejected, workflow_id)

    replayed = assert_projection_equals_replay(task_id)
    assert replayed.status == :rejected
  end

  test "plan workflow projection equals replay" do
    {:ok, task_id} = Current.submit_task(request(:plan), self(), System.tmp_dir!())

    await(:workflow_completed)

    replayed = assert_projection_equals_replay(task_id)
    assert replayed.status == :planned
  end

  test "proposal validation failure projection equals replay" do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)
    :ok = Application.put_env(:current, :proposal_builder, Current.FaultyProposalBuilder)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
    end)

    {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

    validation_failed = await(:proposal_validation_failed)
    await(:workflow_failed, validation_failed.workflow_id)

    replayed = assert_projection_equals_replay(task_id)
    assert replayed.status == :failed
  end
end
