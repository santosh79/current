defmodule Current.Consensus.LogShutdownTest do
  use ExUnit.Case, async: false

  alias Current.Consensus.{Commit, Log}

  setup do
    path = Path.join(System.tmp_dir!(), "log_shutdown_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, path: Path.join(path, "commit_log")}
  end

  describe "supervisor-initiated shutdown" do
    test "the last buffered write is durable after supervisor shutdown",
         %{path: path} do
      {:ok, sup} =
        Supervisor.start_link(
          [{Log, name: :shutdown_test_log, path: path}],
          strategy: :one_for_one
        )

      Enum.each(1..1_000, fn num ->
        commit = Commit.new(num, [], nil)
        :ok = Log.put(commit, :shutdown_test_log)
      end)

      old_log_head = Log.head(:shutdown_test_log)
      old_complete_log = Log.complete_log(:shutdown_test_log)
      assert :ok = Supervisor.stop(sup, :normal)

      {:ok, fresh} = Log.start_link(name: :shutdown_test_log_reopened, path: path)
      new_log_head = Log.head(:shutdown_test_log_reopened)
      new_complete_log = Log.complete_log(:shutdown_test_log_reopened)
      assert new_log_head == old_log_head
      assert new_complete_log == old_complete_log
      GenServer.stop(fresh)
    end
  end
end
