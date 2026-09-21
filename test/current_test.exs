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
    {:ok, task_id} = Current.submit_task(request(), self())

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

  describe "submit_task/2" do
    test "creates a workflow that is queryable through the public API" do
      {:ok, task_id} = Current.submit_task(request(), self())

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
      {:ok, task_id} = Current.submit_task(req, self())

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

      {:ok, task_id} = Current.submit_task(request(), self())

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

      {:ok, task_id} = Current.submit_task(request(), self())
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
