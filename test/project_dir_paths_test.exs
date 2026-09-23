defmodule Current.ProjectDirPathsTest do
  @moduledoc """
  End to end: relative paths from a proposal are resolved against the
  task's project_dir before they are recorded, and paths that resolve
  outside it fail validation.
  """

  use ExUnit.Case, async: false

  alias Current.{Event, Id, Intent, Proposal, Request, Task, WorkflowRunner}

  @receive_timeout 5_000

  defmodule OnePathProposalBuilder do
    @behaviour Current.ProposalBuilder

    def set_path(path), do: :persistent_term.put({__MODULE__, :path}, path)

    @impl true
    def build(%Request{}, workflow_id, _client_module, _timeout_ms, _project_dir) do
      if test_pid = :persistent_term.get({__MODULE__, :test_pid}, nil),
        do: send(test_pid, :builder_called)

      proposal_id = Id.generate()

      intent = %Intent.DeleteFile{
        id: Id.generate(),
        proposal_id: proposal_id,
        path: :persistent_term.get({__MODULE__, :path})
      }

      {:ok,
       %Proposal{
         id: proposal_id,
         workflow_id: workflow_id,
         intents: [intent],
         justification: "test",
         claims: [],
         dependencies: []
       }}
    end
  end

  setup do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)
    :ok = Application.put_env(:current, :proposal_builder, OnePathProposalBuilder)

    project_dir =
      Path.join(Current.TestTmp.dir(), "current_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
      File.rm_rf!(project_dir)
    end)

    %{project_dir: project_dir}
  end

  # :plan mode, so nothing is ever applied -- only resolution and
  # validation are exercised.
  defp submit(project_dir) do
    req = %Request{input: "paths", context: %{}, mode: :plan}
    {:ok, task_id} = Current.submit_task(req, self(), project_dir)

    receive do
      {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
        workflow_id
    after
      @receive_timeout -> flunk("did not receive workflow_created")
    end
  end

  test "a relative path is recorded as absolute, under project_dir", %{project_dir: project_dir} do
    OnePathProposalBuilder.set_path("lib/./old.ex")
    workflow_id = submit(project_dir)

    assert_receive {:proposal_produced,
                    %Event.ProposalProduced{
                      workflow_id: ^workflow_id,
                      proposal: %Proposal{intents: [%Intent.DeleteFile{path: path}]}
                    }},
                   @receive_timeout

    assert path == Path.join([project_dir, "lib", "old.ex"])

    assert_receive {:proposal_validated, %Event.ProposalValidated{workflow_id: ^workflow_id}},
                   @receive_timeout
  end

  test "a path that climbs out of project_dir fails validation", %{project_dir: project_dir} do
    OnePathProposalBuilder.set_path("../../outside.ex")
    workflow_id = submit(project_dir)

    assert_receive {:proposal_validation_failed,
                    %Event.ProposalValidationFailed{workflow_id: ^workflow_id, error: error}},
                   @receive_timeout

    assert error.reason =~ "outside the project directory"
  end

  test "an absolute path elsewhere fails validation", %{project_dir: project_dir} do
    OnePathProposalBuilder.set_path("/etc/passwd")
    workflow_id = submit(project_dir)

    assert_receive {:proposal_validation_failed,
                    %Event.ProposalValidationFailed{workflow_id: ^workflow_id}},
                   @receive_timeout
  end

  describe "a legacy task (recorded before project_dir existed)" do
    test "is abandoned explicitly instead of running against the node's cwd" do
      :persistent_term.put({OnePathProposalBuilder, :test_pid}, self())
      on_exit(fn -> :persistent_term.erase({OnePathProposalBuilder, :test_pid}) end)

      # What TaskStore projects from an upcast v1 TaskCreated.
      legacy_task = %Task{
        id: Id.generate(),
        input: "legacy",
        context: %{},
        mode: :apply,
        project_dir: nil,
        submitted_at: DateTime.utc_now()
      }

      workflow_id = Id.generate()
      {:ok, runner} = WorkflowRunner.start_link({workflow_id, legacy_task, [self()]})
      ref = Process.monitor(runner)

      assert_receive {:workflow_abandoned,
                      %Event.WorkflowAbandoned{workflow_id: ^workflow_id, reason: reason}},
                     @receive_timeout

      assert reason =~ "cannot produce a proposal"
      assert reason =~ "recorded before project_dir existed"

      # Runner and orchestrator both wind down cleanly -- no crash loop.
      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, @receive_timeout
      refute_received :builder_called
      refute_received {:proposal_produced, _}

      assert {:ok, %{status: :abandoned}} = Current.WorkflowStore.get(workflow_id)
    end
  end
end
