defmodule Current.APITest do
  @moduledoc """
  Current.API is what the HTTP router calls. These tests pin
  its contract -- what each function takes, the shape of what it
  returns, and its error values -- not workflow behaviour, which is
  tested through Current.submit_task/3 in test/e2e.

  Nothing here uses listener messages: like a real client, the tests
  only ever poll.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers, only: [request: 0, request: 1, model: 0]

  alias Current.{API, Event}

  @unknown "sha256:ffffffffffff0000"
  @reviewer %{reviewed_by: :api_test}

  defp poll(id, done?, attempts \\ 200) do
    case API.workflow(id) do
      {:ok, view} ->
        cond do
          done?.(view) -> view
          attempts == 0 -> flunk("workflow #{id} stayed #{view.status}")
          true -> retry(id, done?, attempts)
        end

      {:error, :not_found} when attempts > 0 ->
        retry(id, done?, attempts)
    end
  end

  defp retry(id, done?, attempts) do
    Process.sleep(10)
    poll(id, done?, attempts - 1)
  end

  # A finished plan-mode workflow.
  defp planned! do
    {:ok, task_id} = API.submit_task(request(mode: :plan), System.tmp_dir!())
    poll(task_id, & &1.terminal)
  end

  # An apply-mode workflow, stopped at approval; returns its view and proposal id.
  defp waiting_for_approval! do
    {:ok, task_id} = API.submit_task(request(), System.tmp_dir!())
    view = poll(task_id, &(&1.status == :waiting_for_approval))
    {view, proposal_id(view)}
  end

  defp proposal_id(view) do
    Enum.find_value(view.entries, fn
      %{event: %Event.ProposalProduced{proposal: proposal}} -> proposal.id
      _ -> nil
    end)
  end

  defp prefix("sha256:" <> hex, digits \\ 12), do: String.slice(hex, 0, digits)

  describe "submit_task/2" do
    test "returns a task id, and the workflow can be polled by it" do
      assert {:ok, task_id} = API.submit_task(request(mode: :plan), System.tmp_dir!())

      view = poll(task_id, & &1.terminal)
      assert view.status == :planned
      assert view.task.id == task_id
      assert view.task.model == model()
    end

    test "rejects a bad project directory" do
      assert {:error, {:invalid_project_dir, _, :not_a_directory}} =
               API.submit_task(request(), "/definitely/not/here")
    end

    test "rejects a model the catalog doesn't list" do
      assert {:error, {:unknown_model, "openai:nope"}} =
               API.submit_task(request(model: "openai:nope"), System.tmp_dir!())
    end
  end

  describe "workflow/1" do
    test "returns the task and its history in log order, TaskCreated first" do
      view = planned!()

      assert view.mode == :plan
      assert view.terminal
      assert [%{event: %Event.TaskCreated{}} | _] = view.entries
      assert List.last(view.entries).event.__struct__ == Event.WorkflowCompleted

      positions = Enum.map(view.entries, & &1.position)
      assert positions == Enum.sort(positions)
    end

    test "accepts a workflow id, a task id, or a unique prefix of either" do
      view = planned!()

      assert API.workflow(view.workflow_id) == {:ok, view}
      assert API.workflow(view.task.id) == {:ok, view}
      assert API.workflow(prefix(view.workflow_id)) == {:ok, view}
      assert API.workflow(prefix(view.task.id)) == {:ok, view}
    end

    test "unknown and too-short ids are errors" do
      assert {:error, :not_found} = API.workflow(@unknown)
      assert {:error, :prefix_too_short} = API.workflow("ab")
    end
  end

  describe "proposal/1 and review/2" do
    test "a proposal comes with its workflow and what became of it" do
      view = planned!()
      id = proposal_id(view)

      assert {:ok, proposal_view} = API.proposal(prefix(id))
      assert proposal_view.proposal.id == id
      assert proposal_view.workflow_id == view.workflow_id
      assert proposal_view.status == :planned
      assert proposal_view.validation_error == nil

      assert {:error, :not_found} = API.proposal(@unknown)
    end

    test "a review adds the artifacts' contents, cut to max_lines" do
      id = planned!() |> proposal_id()

      assert {:ok, review} = API.review(id, %{max_lines: 2})
      assert review.proposal.id == id
      assert review.limits.max_lines == 2
      assert review.raw_output == nil

      assert [_, _] = excerpts = Map.values(review.artifacts)
      assert Enum.any?(excerpts, &(&1.shown_lines == 1))

      assert {:error, :not_found} = API.review(@unknown, %{})
    end
  end

  describe "artifact/1" do
    test "returns the full id and exact bytes, by id or unique prefix" do
      {:ok, id} = Current.BlobStore.put("api artifact #{System.unique_integer()}")

      assert {:ok, ^id, "api artifact" <> _} = API.artifact(id)
      assert {:ok, ^id, "api artifact" <> _} = API.artifact(String.slice(id, 0, 20))
    end

    test "ambiguous, too-short and unknown ids are errors" do
      ambiguous = colliding_prefix()
      assert {:error, {:ambiguous, [_, _ | _] = ids}} = API.artifact(ambiguous)
      assert Enum.all?(ids, &String.starts_with?(&1, ambiguous))

      assert {:error, :prefix_too_short} = API.artifact("ab")
      assert {:error, :not_found} = API.artifact("not-hex!")
    end

    # Stores blobs until two share a 4-hex-digit prefix (the shortest that
    # is accepted); by the birthday bound that takes a few hundred.
    defp colliding_prefix(seen \\ %{}) do
      {:ok, "sha256:" <> hex} = Current.BlobStore.put("collide #{System.unique_integer()}")
      prefix = "sha256:" <> String.slice(hex, 0, 4)

      if Map.has_key?(seen, prefix),
        do: prefix,
        else: colliding_prefix(Map.put(seen, prefix, true))
    end
  end

  describe "approve/2, reject/2 and apply_proposal/1" do
    test "approve returns the workflow id once the approval is visible, recording the metadata" do
      {view, id} = waiting_for_approval!()

      assert {:ok, workflow_id} = API.approve(prefix(id), @reviewer)
      assert workflow_id == view.workflow_id

      # No polling: approve/2 only returns once the projection has moved on.
      assert {:ok, approved} = API.workflow(workflow_id)
      assert approved.status == :approved

      assert %{event: %Event.ProposalApproved{metadata: @reviewer}} =
               Enum.find(approved.entries, &match?(%{event: %Event.ProposalApproved{}}, &1))
    end

    test "apply_proposal starts applying and returns the workflow id to follow" do
      {view, id} = waiting_for_approval!()
      {:ok, _} = API.approve(id, @reviewer)

      assert {:ok, workflow_id} = API.apply_proposal(id)
      assert workflow_id == view.workflow_id
      assert poll(workflow_id, & &1.terminal).status == :completed
    end

    test "reject returns the workflow id and ends the workflow" do
      {view, id} = waiting_for_approval!()

      assert {:ok, workflow_id} = API.reject(id, @reviewer)
      assert workflow_id == view.workflow_id
      assert {:ok, %{status: :rejected}} = API.workflow(workflow_id)
    end

    test "a step taken in the wrong state is an invalid transition" do
      {_view, id} = waiting_for_approval!()

      assert {:error,
              {:invalid_transition, :waiting_for_approval, Event.EffectApplicationStarted}} =
               API.apply_proposal(id)

      {:ok, _} = API.reject(id, @reviewer)

      assert {:error, {:invalid_transition, :rejected, Event.ProposalApproved}} =
               API.approve(id, @reviewer)
    end

    test "a plan-mode proposal is refused with its mode" do
      id = planned!() |> proposal_id()

      assert {:error, {:not_apply_mode, :plan}} = API.approve(id, @reviewer)
      assert {:error, {:not_apply_mode, :plan}} = API.reject(id, @reviewer)
      assert {:error, {:not_apply_mode, :plan}} = API.apply_proposal(id)
    end

    test "an unknown proposal is not found" do
      assert {:error, :not_found} = API.approve(@unknown, @reviewer)
      assert {:error, :not_found} = API.reject(@unknown, @reviewer)
      assert {:error, :not_found} = API.apply_proposal(@unknown)
    end
  end

  describe "health/0 and models/0" do
    test "health reports readiness, the WAL head and the builder configuration" do
      health = API.health()

      assert health.status == :ready
      assert is_integer(health.wal_head)
      assert health.proposal_builder == Application.fetch_env!(:current, :proposal_builder)
    end

    test "models lists the catalog's provider-qualified names" do
      models = API.models()

      assert model() in models
      assert Enum.all?(models, &(&1 =~ ~r/^[a-z]+:.+/))
      assert models == Enum.sort(models)
    end
  end
end
