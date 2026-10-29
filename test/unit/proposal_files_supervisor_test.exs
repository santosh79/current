defmodule Current.ProposalFilesSupervisorTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:current, :generate_proposal_files)
    Application.put_env(:current, :generate_proposal_files, false)
    restart_application()

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:current, :generate_proposal_files, value)
        :error -> Application.delete_env(:current, :generate_proposal_files)
      end

      restart_application()
    end)

    :ok
  end

  test "the optional supervisor is disabled by default and may give up without the runtime" do
    refute Process.whereis(Current.ProposalFiles.Supervisor)
    refute Process.whereis(Current.ProposalFiles)

    Application.put_env(:current, :generate_proposal_files, true)
    restart_application()

    runtime = await_pid(Current.RuntimeSupervisor)
    task_store = await_pid(Current.TaskStore)
    files_supervisor = await_pid(Current.ProposalFiles.Supervisor)

    Enum.reduce(1..3, await_pid(Current.ProposalFiles), fn _, previous_writer ->
      Process.exit(previous_writer, :kill)
      await_new_pid(Current.ProposalFiles, previous_writer)
    end)

    supervisor_ref = Process.monitor(files_supervisor)
    Process.exit(Process.whereis(Current.ProposalFiles), :kill)

    assert_receive {:DOWN, ^supervisor_ref, :process, ^files_supervisor, _reason}, 2_000
    refute Process.whereis(Current.ProposalFiles.Supervisor)
    refute Process.whereis(Current.ProposalFiles)

    assert Process.whereis(Current.RuntimeSupervisor) == runtime
    assert Process.alive?(runtime)
    assert Process.whereis(Current.TaskStore) == task_store
    assert Process.alive?(task_store)
  end

  defp restart_application do
    :ok = Application.stop(:current)
    :ok = Application.start(:current)
  end

  defp await_pid(name, attempts \\ 200)

  defp await_pid(name, 0), do: flunk("#{inspect(name)} did not start")

  defp await_pid(name, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> pid
      _ ->
        Process.sleep(10)
        await_pid(name, attempts - 1)
    end
  end

  defp await_new_pid(name, old_pid, attempts \\ 200)

  defp await_new_pid(name, _old_pid, 0), do: flunk("#{inspect(name)} did not restart")

  defp await_new_pid(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ ->
        Process.sleep(10)
        await_new_pid(name, old_pid, attempts - 1)
    end
  end
end
