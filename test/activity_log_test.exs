defmodule Current.ActivityLogTest do
  use ExUnit.Case, async: false

  alias Current.{ActivityLog, Request}

  # The runtime's own ActivityLog, with its output redirected to a
  # StringIO for the test.
  setup do
    previous = Application.get_env(:current, :activity_log)
    Application.put_env(:current, :activity_log, true)

    log = Process.whereis(ActivityLog)
    leader = Process.info(log, :group_leader) |> elem(1)
    {:ok, io} = StringIO.open("")
    Process.group_leader(log, io)

    on_exit(fn ->
      if Process.alive?(log), do: Process.group_leader(log, leader)

      if previous == nil,
        do: Application.delete_env(:current, :activity_log),
        else: Application.put_env(:current, :activity_log, previous)
    end)

    %{io: io, log: log}
  end

  defp output(io, log) do
    # A synchronous round trip, so everything already sent to the log
    # process has been printed.
    :sys.get_state(log)
    io |> StringIO.contents() |> elem(1)
  end

  test "each WAL commit of a task is printed with its index, the task, and timings", %{
    io: io,
    log: log
  } do
    request = %Request{input: "add email validation", context: %{}, mode: :plan}
    {:ok, "sha256:" <> task_hex} = Current.submit_task(request, self(), System.tmp_dir!())

    assert_receive {:workflow_completed, _event}, 5_000
    out = output(io, log)
    task = "task " <> binary_part(task_hex, 0, 12)

    for name <- ~w(TaskCreated WorkflowCreated ProposalProductionStarted ProposalProduced
                   ProposalValidated WorkflowCompleted) do
      assert out =~ ~r/WAL #\d+ +[0-9a-f]{8}  #{name} +#{task}/
    end

    assert out =~ ~s(plan · "add email validation")
    assert out =~ ~r/ProposalProduced .* · 1 intent · model \d+\.\ds/
    assert out =~ ~r/WorkflowCompleted .* completed · total \d+\.\ds/
  end

  test "WAL indexes are consecutive", %{io: io, log: log} do
    request = %Request{input: "x", context: %{}, mode: :plan}
    {:ok, _task_id} = Current.submit_task(request, self(), System.tmp_dir!())
    assert_receive {:workflow_completed, _event}, 5_000

    indexes =
      Regex.scan(~r/WAL #(\d+)/, output(io, log), capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    assert indexes == Enum.to_list(hd(indexes)..(hd(indexes) + length(indexes) - 1))
  end

  test "RPC requests are printed, and a polling client only once", %{io: io, log: log} do
    for _poll <- 1..5, do: ActivityLog.rpc(:workflow, ["sha256:abcd"])
    ActivityLog.rpc(:submit_task, [~s(plan "x"), "/nope"])
    ActivityLog.rpc_result(:submit_task, "✗ rejected: /nope (not_a_directory)")

    out = output(io, log)
    assert length(Regex.scan(~r/← workflow +sha256:abcd/, out)) == 1
    assert out =~ ~r/← submit_task +plan "x"\n +\/nope\n/
    assert out =~ "→ submit_task      ✗ rejected: /nope (not_a_directory)"
  end

  test "nothing is printed unless activity_log is on", %{io: io, log: log} do
    Application.put_env(:current, :activity_log, false)

    {:ok, _task_id} =
      Current.submit_task(
        %Request{input: "x", context: %{}, mode: :plan},
        self(),
        System.tmp_dir!()
      )

    assert_receive {:workflow_completed, _event}, 5_000

    assert output(io, log) == ""
  end
end
