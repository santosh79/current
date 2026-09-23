defmodule CurrentTest do
  use ExUnit.Case, async: false

  doctest Current

  alias Current.{Event, Proposal, Request, Error.ProposalProductionError}

  @receive_timeout 5_000

  defp request do
    %Request{
      input: "add email validation to signup flow",
      context: %{}
    }
  end

  defp submit_and_await_valid_proposal do
    {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
          workflow_id
      after
        @receive_timeout ->
          flunk("did not receive workflow_created")
      end

    proposal =
      receive do
        {:proposal_produced,
         %Event.ProposalProduced{workflow_id: ^workflow_id, proposal: proposal}} ->
          assert %Proposal{} = proposal
          proposal
      after
        @receive_timeout ->
          flunk("did not receive proposal_produced")
      end

    receive do
      {:proposal_validated,
       %Event.ProposalValidated{workflow_id: ^workflow_id, proposal: %Proposal{id: proposal_id}}} ->
        assert proposal_id == proposal.id
    after
      @receive_timeout ->
        flunk("did not receive proposal_validated")
    end

    {:ok, task_id, workflow_id, proposal}
  end

  describe "submit_task/3" do
    test "creates a workflow that is queryable through the public API" do
      {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

      receive do
        {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
          assert {:ok, workflow} = Current.get_workflow(task_id)
          assert workflow.id == workflow_id
          assert workflow.task_id == task_id

          assert {:ok, status} = Current.get_status(task_id)
          assert status in [:created, :planning, :validating, :waiting_for_approval]
      after
        @receive_timeout ->
          flunk("did not receive workflow_created")
      end
    end

    test "defaults project_dir to the working directory, recorded canonically" do
      {:ok, task_id} = Current.submit_task(request(), self())
      await_workflow_created(task_id)

      assert {:ok, %Current.Task{project_dir: project_dir}} = Current.Task.get(task_id)
      assert {:ok, project_dir} == Current.IntentPaths.realpath(File.cwd!())
    end

    test "resolves an explicit relative project_dir at submission time" do
      {:ok, task_id} = Current.submit_task(request(), self(), "lib")
      await_workflow_created(task_id)

      assert {:ok, %Current.Task{project_dir: project_dir}} = Current.Task.get(task_id)
      assert {:ok, project_dir} == Current.IntentPaths.realpath(Path.join(File.cwd!(), "lib"))
    end

    test "records the physical directory, not the symlink used to name it" do
      base = Path.join(Current.TestTmp.dir(), "current_link_#{System.unique_integer([:positive])}")
      real = Path.join(base, "real_project")
      link = Path.join(base, "app")
      File.mkdir_p!(real)
      File.ln_s!(real, link)
      on_exit(fn -> File.rm_rf!(base) end)

      {:ok, task_id} = Current.submit_task(request(), self(), link)
      await_workflow_created(task_id)

      assert {:ok, %Current.Task{project_dir: ^real}} = Current.Task.get(task_id)

      # Repointing the symlink afterwards changes nothing about the task.
      other = Path.join(base, "other_project")
      File.mkdir_p!(other)
      File.rm!(link)
      File.ln_s!(other, link)

      assert {:ok, %Current.Task{project_dir: ^real}} = Current.Task.get(task_id)
    end

    test "rejects a project_dir that doesn't exist or isn't a directory" do
      missing = Path.join(Current.TestTmp.dir(), "current_missing_#{System.unique_integer([:positive])}")

      assert {:error, {:invalid_project_dir, ^missing, :not_a_directory}} =
               Current.submit_task(request(), self(), missing)

      file = missing <> ".txt"
      File.write!(file, "")
      on_exit(fn -> File.rm(file) end)

      assert {:error, {:invalid_project_dir, ^file, :not_a_directory}} =
               Current.submit_task(request(), self(), file)

      refute_receive {:workflow_created, _}, 200
    end

    test "rejects a project_dir that is a symlink loop" do
      base = Path.join(Current.TestTmp.dir(), "current_loop_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      File.ln_s!("b", Path.join(base, "a"))
      File.ln_s!("a", Path.join(base, "b"))
      on_exit(fn -> File.rm_rf!(base) end)

      loop = Path.join(base, "a")

      assert {:error, {:invalid_project_dir, ^loop, :too_many_links}} =
               Current.submit_task(request(), self(), loop)
    end

    test "rejects a project_dir containing '..' without recording anything" do
      for dir <- ["..", "../../etc", "lib/../..", "/srv/app/../../etc", "lib/.."] do
        assert {:error, {:invalid_project_dir, ^dir, :parent_segment}} =
                 Current.submit_task(request(), self(), dir)
      end

      refute_receive {:workflow_created, _}, 200
    end

    test "does not mistake a name that merely contains dots for '..'" do
      dir = Path.join(System.tmp_dir!(), "current..dots_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, _task_id} = Current.submit_task(request(), self(), dir)
    end
  end

  defp await_workflow_created(task_id) do
    receive do
      {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_created")
    end
  end

  describe "get_status/1" do
    test "returns not_found for an unknown task id" do
      unknown_task_id =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      assert {:error, :not_found} = Current.get_status(unknown_task_id)
    end
  end

  describe "review_proposal/2" do
    test "returns not_found for an unknown proposal" do
      unknown_proposal_id =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      assert {:error, :not_found} =
               Current.review_proposal(
                 unknown_proposal_id,
                 {:approve, %{reviewed_by: :test_user}}
               )
    end

    test "approving a validated proposal completes the workflow" do
      {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{reviewed_by: :test_user}}
               )

      receive do
        {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive workflow_completed")
      end

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.id == workflow_id
      assert workflow.status == :completed
      assert workflow.proposal.id == proposal.id
      assert workflow.result != nil
    end

    test "rejecting a validated proposal leaves the workflow rejected" do
      {:ok, task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:reject, %{reviewed_by: :test_user}}
               )

      receive do
        {:proposal_rejected, %Event.ProposalRejected{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive proposal_rejected")
      end

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.id == workflow_id
      assert workflow.status == :rejected
      assert workflow.proposal.id == proposal.id
      assert workflow.result == nil
      assert workflow.completed_at == nil

      refute_receive {:proposal_approved, %Event.ProposalApproved{workflow_id: ^workflow_id}}, 200

      refute_receive {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}},
                     200
    end

    test "reviewing an already-rejected proposal returns an invalid transition error" do
      {:ok, _task_id, workflow_id, proposal} = submit_and_await_valid_proposal()

      assert :ok = Current.review_proposal(proposal.id, {:reject, %{reviewed_by: :test_user}})

      receive do
        {:proposal_rejected, %Event.ProposalRejected{workflow_id: ^workflow_id}} -> :ok
      after
        @receive_timeout -> flunk("did not receive proposal_rejected")
      end

      failed_before = length(Current.Consensus.FailedEventsLog.all())

      assert {:error, {:invalid_transition, :rejected, Event.ProposalApproved}} =
               Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :test_user}})

      assert {:error, {:invalid_transition, :rejected, Event.ProposalRejected}} =
               Current.review_proposal(proposal.id, {:reject, %{reviewed_by: :test_user}})

      # Nothing was proposed, so nothing could have been rejected at commit time.
      assert length(Current.Consensus.FailedEventsLog.all()) == failed_before
    end

    test "reviewing a plan-mode proposal returns an invalid transition error" do
      req = %Request{input: "add email validation", context: %{}, mode: :plan}
      {:ok, task_id} = Current.submit_task(req, self(), System.tmp_dir!())

      workflow_id =
        receive do
          {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
            workflow_id
        after
          @receive_timeout -> flunk("did not receive workflow_created")
        end

      proposal =
        receive do
          {:proposal_produced, %Event.ProposalProduced{workflow_id: ^workflow_id, proposal: p}} ->
            p
        after
          @receive_timeout -> flunk("did not receive proposal_produced")
        end

      receive do
        {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} -> :ok
      after
        @receive_timeout -> flunk("did not receive workflow_completed")
      end

      assert {:error, {:invalid_transition, :planned, Event.ProposalApproved}} =
               Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :test_user}})
    end
  end

  describe "workflow failure" do
    test "an invalid proposal fails the workflow" do
      previous_builder = Application.fetch_env!(:current, :proposal_builder)

      :ok = Application.put_env(:current, :proposal_builder, Current.FaultyProposalBuilder)

      on_exit(fn ->
        :ok = Application.put_env(:current, :proposal_builder, previous_builder)
      end)

      {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())

      workflow_id =
        receive do
          {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
            workflow_id
        after
          @receive_timeout ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_validation_failed, %Event.ProposalValidationFailed{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive proposal_validation_failed")
      end

      receive do
        {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} ->
          :ok
      after
        @receive_timeout ->
          flunk("did not receive workflow_failed")
      end

      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.status == :failed
      assert workflow.error == "proposal validation failed"
      assert workflow.result == nil
    end

    test "a proposal builder that returns an error fails the workflow" do
      previous_builder = Application.fetch_env!(:current, :proposal_builder)

      :ok =
        Application.put_env(:current, :proposal_builder, Current.ErrorReturningProposalBuilder)

      on_exit(fn ->
        :ok = Application.put_env(:current, :proposal_builder, previous_builder)
      end)

      {:ok, task_id} = Current.submit_task(request(), self(), System.tmp_dir!())
      reason = await_proposal_production_failure(task_id)
      assert reason =~ "rate_limited"
    end
  end

  test "subscriptions are removed automatically when subscriber exits" do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Current.EventNotifier.subscribe(self(), :task_created)
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    receive do
      :subscribed -> :ok
    end

    assert Registry.lookup(Current.EventRegistry, :task_created)
           |> Enum.any?(fn {registered_pid, _} ->
             registered_pid == pid
           end)

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert_eventually(fn ->
      Registry.lookup(Current.EventRegistry, :task_created)
      |> Enum.all?(fn {registered_pid, _} ->
        registered_pid != pid
      end)
    end)
  end

  test "one process matching several keys receives one notification" do
    {:ok, _task_id, workflow_id, proposal} = submit_and_await_valid_proposal()
    :ok = Current.EventNotifier.subscribe(self(), :all)
    :ok = Current.EventNotifier.subscribe(self(), :workflow_completed)
    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :all)
    :ok = Current.EventNotifier.subscribe(self(), workflow_id, :workflow_completed)

    :ok = Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :test_user}})

    assert_receive {:event_committed,
                    %Current.EventStore.Entry{event: %Current.Event.WorkflowCompleted{}}}

    refute_receive {:event_committed,
                    %Current.EventStore.Entry{event: %Current.Event.WorkflowCompleted{}}},
                   50
  end

  defp await_proposal_production_failure(task_id) do
    workflow_id =
      receive do
        {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
          workflow_id
      after
        @receive_timeout -> flunk("did not receive workflow_created")
      end

    error =
      receive do
        {:proposal_production_failed,
         %Event.ProposalProductionFailed{workflow_id: ^workflow_id, error: error}} ->
          error
      after
        @receive_timeout -> flunk("did not receive proposal_production_failed")
      end

    receive do
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("did not receive workflow_failed")
    end

    reason = ProposalProductionError.message(error)
    assert {:ok, %{status: :failed, error: ^reason, result: nil}} = Current.get_workflow(task_id)
    reason
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(_fun, 0) do
    flunk("condition did not become true")
  end

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
