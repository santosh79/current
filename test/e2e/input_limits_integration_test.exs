defmodule Current.InputLimitsIntegrationTest do
  @moduledoc """
  Runs against the real application with tiny limits that it sets for its
  own duration (see `setup`) and restores afterwards, and checks that oversized input is refused *and leaves
  no trace*: nothing committed to the WAL, no workflow state changed.

  Not async: it reads the shared WAL and the shared workflow projections.
  """
  use ExUnit.Case, async: false

  alias Current.{InputLimits, Request}
  alias Current.HTTP.Router

  # Production-like defaults everywhere else in the suite; small limits here
  # only. Limits are read on every call, so changing the env is enough.
  @limits [prompt: 256, feedback: 128, message: 64, reviewed_by: 32, model: 64, dir: 512]

  setup do
    previous = Application.get_env(:current, :input_limits)
    Application.put_env(:current, :input_limits, @limits)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:current, :input_limits)
        value -> Application.put_env(:current, :input_limits, value)
      end
    end)

    :ok
  end

  ## Helpers

  # The catalog is filled asynchronously at startup, so wait for it. Which
  # models exist is up to the test catalog clients; any one will do.
  defp a_model do
    Enum.find_value(1..100, fn _ ->
      case Current.API.models() do
        [model | _] -> model
        [] -> Process.sleep(50) && nil
      end
    end) || flunk("the model catalog stayed empty; check the test catalog clients")
  end

  defp request(overrides) do
    struct!(
      %Request{input: "add a validation", context: %{}, model: "unset", mode: :apply},
      overrides
    )
  end

  defp submit(overrides, dir \\ System.tmp_dir!()),
    do: Current.submit_task(request(overrides), self(), dir)

  defp bytes(n), do: String.duplicate("a", n)

  # Everything ever committed, straight from the WAL. A commit is durable
  # before submit_task returns, so no waiting is needed to prove a negative.
  defp wal_events, do: Current.Consensus.Log.complete_log() |> Enum.flat_map(& &1.events)

  defp task_created?(fun),
    do: Enum.any?(wal_events(), &(match?(%Current.Event.TaskCreated{}, &1) and fun.(&1)))

  defp revision_requested?(workflow_id, feedback) do
    Enum.any?(wal_events(), fn
      %Current.Event.ProposalRevisionRequested{workflow_id: ^workflow_id, feedback: ^feedback} ->
        true

      _ ->
        false
    end)
  end

  defp await_status(task_id, status, attempts \\ 100) do
    case Current.WorkflowStore.get_by_task_id(task_id) do
      {:ok, %{status: ^status} = workflow} ->
        workflow

      other when attempts > 0 ->
        _ = other
        Process.sleep(50)
        await_status(task_id, status, attempts - 1)

      other ->
        flunk("workflow of task #{task_id} never reached #{status}: #{inspect(other)}")
    end
  end

  # An :apply workflow parked at waiting_for_approval, and its proposal.
  defp waiting_proposal do
    {:ok, task_id} = submit(model: a_model())
    workflow = await_status(task_id, :waiting_for_approval)
    {workflow, Current.Workflow.current_proposal(workflow)}
  end

  defp post_json(path, body) do
    conn =
      Plug.Test.conn(:post, path, JSON.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    {conn.status, JSON.decode!(conn.resp_body)}
  end

  test "the limits in force are the small ones set by this module's setup" do
    assert InputLimits.max(:prompt) == 256
    assert InputLimits.max(:model) == 64
    assert InputLimits.max(:feedback) == 128
  end

  ## submit_task

  describe "submit_task/3" do
    test "a prompt one byte over the limit is refused and never committed" do
      too_big = bytes(InputLimits.max(:prompt) + 1)
      max = InputLimits.max(:prompt)

      assert {:error, {:too_large, :prompt, size, ^max}} =
               submit(input: too_big, model: a_model())

      assert size == max + 1
      refute task_created?(&(&1.input == too_big))
    end

    test "a prompt exactly at the limit is accepted and committed" do
      at_limit = bytes(InputLimits.max(:prompt))

      assert {:ok, task_id} = submit(input: at_limit, model: a_model())
      assert task_created?(&(&1.task_id == task_id and &1.input == at_limit))
    end

    test "the limit counts bytes, not characters" do
      # Half the limit in two-byte characters is exactly the limit in bytes
      # (accepted); one more character is two bytes over (refused).
      half = div(InputLimits.max(:prompt), 2)
      fits = String.duplicate("é", half)
      over = fits <> "é"

      assert {:ok, _task_id} = submit(input: fits, model: a_model())
      assert {:error, {:too_large, :prompt, _, _}} = submit(input: over, model: a_model())
    end

    test "a 10 MB model name is refused before the catalog is consulted" do
      # Not a catalog entry, so had the catalog been asked this would be
      # {:unknown_model, _}. too_large proves the size check ran first.
      huge = String.duplicate("m", 10_000_000)
      max = InputLimits.max(:model)

      assert {:error, {:too_large, :model, 10_000_000, ^max}} = submit(model: huge)
      refute task_created?(&(&1.model == huge))
    end

    test "a model name at the limit passes the size check and meets the catalog" do
      at_limit = bytes(InputLimits.max(:model))
      assert {:error, {:unknown_model, ^at_limit}} = submit(model: at_limit)
    end

    test "a project directory over the limit is refused before the filesystem is touched" do
      long_dir = "/" <> bytes(InputLimits.max(:dir))

      assert {:error, {:too_large, :dir, _, _}} = submit([model: a_model()], long_dir)
      refute task_created?(&(&1.project_dir == long_dir))
    end

    test "when several inputs are too large, the first in the check order is reported" do
      assert {:error, {:too_large, :prompt, _, _}} =
               submit(input: bytes(InputLimits.max(:prompt) + 1), model: bytes(10_000))
    end

    test "timeouts outside one second to one hour are refused and never committed" do
      for bad <- [0, 999, 3_600_001, -1] do
        assert {:error, {:invalid_timeout, ^bad}} =
                 submit(model: a_model(), input: "timeout #{bad}", timeout_ms: bad)

        refute task_created?(&(&1.input == "timeout #{bad}"))
      end
    end

    test "the timeout boundaries themselves are accepted" do
      for good <- [1_000, 3_600_000] do
        assert {:ok, _} = submit(model: a_model(), timeout_ms: good)
      end
    end
  end

  ## Revisions and decisions

  describe "revising and deciding" do
    test "oversized feedback is refused; the workflow stays waiting and records nothing" do
      {workflow, proposal} = waiting_proposal()
      feedback = bytes(InputLimits.max(:feedback) + 1)
      max = InputLimits.max(:feedback)

      assert {:error, {:too_large, :feedback, size, ^max}} =
               Current.request_revision(proposal.id, feedback, %{reviewed_by: "tester"})

      assert size == max + 1

      assert {:ok, %{status: :waiting_for_approval}} = Current.WorkflowStore.get(workflow.id)

      # The WAL is the proof: EventStore lags it, so it could look empty
      # even if something had been committed.
      refute revision_requested?(workflow.id, feedback)
    end

    test "feedback exactly at the limit is accepted" do
      {workflow, proposal} = waiting_proposal()
      feedback = bytes(InputLimits.max(:feedback))

      assert :ok = Current.request_revision(proposal.id, feedback, %{reviewed_by: "tester"})

      # Read the WAL, not EventStore: the commit is durable before the call
      # returns, but EventStore is filled asynchronously by EventCommitter.
      assert revision_requested?(workflow.id, feedback)
    end

    test "an oversized approval message is refused, and a valid one then still works" do
      {workflow, proposal} = waiting_proposal()
      message = bytes(InputLimits.max(:message) + 1)

      assert {:error, {:too_large, :message, _, _}} =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{message: message, reviewed_by: "t"}}
               )

      assert {:ok, %{status: :waiting_for_approval}} = Current.WorkflowStore.get(workflow.id)

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{message: "ok", reviewed_by: "t"}}
               )

      assert %{status: :approved} = await_status(workflow.task_id, :approved)
    end

    test "an oversized reviewer name is refused" do
      {workflow, proposal} = waiting_proposal()
      reviewer = bytes(InputLimits.max(:reviewed_by) + 1)

      assert {:error, {:too_large, :reviewed_by, _, _}} =
               Current.review_proposal(
                 proposal.id,
                 {:reject, %{message: "no", reviewed_by: reviewer}}
               )

      assert {:ok, %{status: :waiting_for_approval}} = Current.WorkflowStore.get(workflow.id)
    end
  end

  ## HTTP

  describe "POST /v1/tasks" do
    defp task_body(overrides) do
      Map.merge(
        %{"prompt" => "add a validation", "model" => a_model(), "dir" => System.tmp_dir!()},
        overrides
      )
    end

    test "an oversized prompt answers 422 too_large, naming the field and sizes" do
      max = InputLimits.max(:prompt)
      body = task_body(%{"prompt" => bytes(max + 1)})

      assert {422, %{"error" => %{"code" => "too_large", "details" => details}}} =
               post_json("/v1/tasks", body)

      assert details == %{"field" => "prompt", "size" => max + 1, "max" => max}
      refute task_created?(&(&1.input == body["prompt"]))
    end

    test "an oversized model answers 422 too_large" do
      assert {422, %{"error" => %{"code" => "too_large", "details" => %{"field" => "model"}}}} =
               post_json("/v1/tasks", task_body(%{"model" => bytes(InputLimits.max(:model) + 1)}))
    end

    test "an out-of-range timeout answers 422 invalid_timeout" do
      assert {422, %{"error" => %{"code" => "invalid_timeout"}}} =
               post_json("/v1/tasks", task_body(%{"timeout_ms" => 500}))
    end

    test "a prompt at the limit answers 202 with a task id" do
      body = task_body(%{"prompt" => bytes(InputLimits.max(:prompt))})
      assert {202, %{"task_id" => task_id}} = post_json("/v1/tasks", body)
      assert task_created?(&(&1.task_id == task_id))
    end

    test "a body over the parser limit answers 413" do
      # Far beyond the router's Plug.Parsers length (and any prompt limit).
      conn =
        Plug.Test.conn(
          :post,
          "/v1/tasks",
          JSON.encode!(task_body(%{"prompt" => bytes(2_000_000)}))
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      # Plug.ErrorHandler sends the response, then re-raises.
      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        Router.call(conn, Router.init([]))
      end

      assert {413, _headers, body} = Plug.Test.sent_resp(conn)
      assert %{"error" => %{"code" => "request_too_large"}} = JSON.decode!(body)
    end
  end

  describe "POST /v1/proposals/:id/revise" do
    test "oversized feedback answers 422 too_large and the workflow stays waiting" do
      {workflow, proposal} = waiting_proposal()
      max = InputLimits.max(:feedback)

      assert {422, %{"error" => %{"code" => "too_large", "details" => details}}} =
               post_json("/v1/proposals/#{proposal.id}/revise", %{"feedback" => bytes(max + 1)})

      assert details == %{"field" => "feedback", "size" => max + 1, "max" => max}
      assert {:ok, %{status: :waiting_for_approval}} = Current.WorkflowStore.get(workflow.id)
    end
  end
end
