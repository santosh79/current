defmodule Current.RPCTest do
  use ExUnit.Case, async: false

  alias Current.{Request, RPC}

  test "submit_task/2 returns a task id and the workflow can be polled by it" do
    request = %Request{input: "add email validation", context: %{}, mode: :plan}
    assert {:ok, task_id} = RPC.submit_task(request, System.tmp_dir!())

    view = poll_until_terminal(task_id)
    assert view.status == :planned
    assert view.task.id == task_id
  end

  test "submit_task/2 rejects a bad project directory without recording anything" do
    request = %Request{input: "x", context: %{}, mode: :plan}

    assert {:error, {:invalid_project_dir, _, :not_a_directory}} =
             RPC.submit_task(request, "/definitely/not/here")
  end

  test "health/0 reports readiness, the WAL head and the model configuration" do
    health = RPC.health()
    assert health.status == :ready
    assert is_integer(health.wal_head)
    assert health.proposal_builder == Application.fetch_env!(:current, :proposal_builder)
  end

  defp poll_until_terminal(task_id, attempts \\ 100) do
    case RPC.workflow(task_id) do
      {:ok, %{terminal: true} = view} ->
        view

      _not_yet when attempts > 0 ->
        Process.sleep(20)
        poll_until_terminal(task_id, attempts - 1)

      other ->
        flunk("workflow never became terminal: #{inspect(other)}")
    end
  end
end
