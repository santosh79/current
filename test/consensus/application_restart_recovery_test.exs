defmodule Current.Consensus.ApplicationRestartRecoveryTest do
  use ExUnit.Case, async: false

  alias Current.{Event, EventStore, Id, Request}
  alias Current.Consensus.{FailedEventsLog, Log}

  @receive_timeout 5_000

  setup do
    path = Path.join(System.tmp_dir!(), "current_wal_test_#{System.unique_integer([:positive])}")
    old_path = Application.get_env(:current, :data_dir)
    :ok = Application.put_env(:current, :data_dir, path)

    on_exit(fn ->
      :ok = Application.put_env(:current, :data_dir, old_path)
      restart_application()
      File.rm_rf!(path)
    end)

    restart_application()

    :ok
  end

  defp restart_application do
    :ok = Application.stop(:current)
    :ok = Application.start(:current)
  end

  defp crash_log_and_await_runtime_rebuild do
    old_runtime = Process.whereis(Current.RuntimeSupervisor)
    old_log = Process.whereis(Current.Consensus.Log)

    ref = Process.monitor(old_log)
    Process.exit(old_log, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_log, :killed}, 1_000
    :ok = await_runtime_ready(old_runtime)

    :ok = await_new_pid(Current.RuntimeSupervisor, old_runtime)
    :ok = await_new_pid(Current.Consensus.Log, old_log)

    :ok
  end

  defp await_runtime_ready(old_runtime, attempts \\ 100)

  defp await_runtime_ready(_old_runtime, 0) do
    flunk("runtime did not rebuild in time")
  end

  defp await_runtime_ready(old_runtime, attempts) do
    runtime = Process.whereis(Current.RuntimeSupervisor)

    ready? =
      is_pid(runtime) and
        runtime != old_runtime and
        is_pid(Process.whereis(Current.Consensus.Log)) and
        is_pid(Process.whereis(Current.EventStore)) and
        is_pid(Process.whereis(Current.Consensus.SingleNodeServer)) and
        is_pid(Process.whereis(Current.EventCommitter)) and
        is_pid(Process.whereis(Current.TaskStore)) and
        is_pid(Process.whereis(Current.ProposalStore)) and
        is_pid(Process.whereis(Current.WorkflowStore)) and
        is_pid(Process.whereis(Current.WorkflowSupervisor)) and
        is_pid(Process.whereis(Current.TaskDispatcher))

    if ready? do
      :ok
    else
      Process.sleep(10)
      await_runtime_ready(old_runtime, attempts - 1)
    end
  end

  defp await_new_pid(name, old_pid, attempts \\ 100)

  defp await_new_pid(name, _old_pid, 0) do
    flunk("#{inspect(name)} did not come back with a new pid in time")
  end

  defp await_new_pid(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

      _ ->
        Process.sleep(10)
        await_new_pid(name, old_pid, attempts - 1)
    end
  end

  test "a commit proposed after an application restart continues the existing chain" do
    workflow_id = Id.generate()

    events = [
      %Event.WorkflowCreated{
        id: Id.generate(),
        workflow_id: workflow_id,
        task_id: Id.generate(),
        mode: :apply,
        timestamp: DateTime.utc_now()
      },
      %Event.ProposalProductionStarted{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      }
    ]

    Enum.each(events, fn e -> assert :ok = Current.Consensus.propose(e) end)

    assert {:ok, head_before} = Log.head()

    restart_application()

    # The durable head must survive the restart untouched, before any
    # new proposal happens.
    assert {:ok, ^head_before} = Log.head()

    next_event = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    assert :ok = Current.Consensus.propose(next_event)
    assert {:ok, new_head} = Log.head()

    assert new_head.index == head_before.index + 1,
           "expected the post-restart commit to continue at #{head_before.index + 1}, " <>
             "got #{new_head.index} -- SingleNodeServer restarted its counter from 0 " <>
             "instead of resuming from the durable head"

    assert new_head.previous_hash == Current.Consensus.Commit.hash(head_before),
           "expected the post-restart commit's previous_hash to chain to the pre-restart " <>
             "head's hash -- the hash chain is broken across the restart"
  end

  test "submit_task/2 still works normally after an application restart" do
    restart_application()

    {:ok, task_id} =
      Current.submit_task(
        %Request{input: "post-restart sanity check", context: %{}},
        self(),
        System.tmp_dir!()
      )

    assert_receive {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id}}, 5_000
  end

  test "a commit proposed after Log crashes directly continues the existing chain, via runtime self-healing" do
    workflow_id = Id.generate()

    events = [
      %Event.WorkflowCreated{
        id: Id.generate(),
        workflow_id: workflow_id,
        task_id: Id.generate(),
        mode: :apply,
        timestamp: DateTime.utc_now()
      },
      %Event.ProposalProductionStarted{
        id: Id.generate(),
        workflow_id: workflow_id,
        timestamp: DateTime.utc_now()
      }
    ]

    Enum.each(events, fn e -> assert :ok = Current.Consensus.propose(e) end)

    assert {:ok, head_before} = Log.head()

    crash_log_and_await_runtime_rebuild()

    assert {:ok, ^head_before} = Log.head()

    next_event = %Event.ProposalProduced{
      id: Id.generate(),
      workflow_id: workflow_id,
      timestamp: DateTime.utc_now()
    }

    assert :ok = Current.Consensus.propose(next_event)
    assert {:ok, new_head} = Log.head()

    assert new_head.index == head_before.index + 1,
           "expected the post-recovery commit to continue at #{head_before.index + 1}, " <>
             "got #{new_head.index} -- the rebuilt runtime did not resume from the durable head"

    assert new_head.previous_hash == Current.Consensus.Commit.hash(head_before),
           "expected the post-recovery commit's previous_hash to chain to the pre-crash " <>
             "head's hash -- the hash chain is broken across the runtime rebuild"
  end

  test "submit_task/2 still works normally after Log crashes directly, via runtime self-healing" do
    crash_log_and_await_runtime_rebuild()

    {:ok, task_id} =
      Current.submit_task(
        %Request{input: "post-recovery sanity check", context: %{}},
        self(),
        System.tmp_dir!()
      )

    assert_receive {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id}}, 5_000
  end

  # ---------------------------------------------------------------------
  # EventStore / FailedEventsLog survival across a self-healing recovery
  # ---------------------------------------------------------------------

  test "runtime rebuild reconstructs EventStore and FailedEventsLog from the WAL" do
    requests =
      1..6
      |> Enum.map(fn i ->
        mode = if rem(i, 2) == 0, do: :plan, else: :apply
        {i, %Request{input: "task #{i}", context: %{}, mode: mode}}
      end)

    # 1/ submit everything, keeping track of which task_id came from
    # which original index (so we know which ones are :plan vs :apply
    # and can decide accept/reject deterministically later).
    tasks =
      Enum.map(requests, fn {i, req} ->
        {:ok, task_id} = Current.submit_task(req, self(), System.tmp_dir!())
        %{index: i, task_id: task_id, mode: req.mode}
      end)

    # 2/ resolve every task_id to a workflow_id first, before reacting
    # to anything workflow-specific -- otherwise a message for a later
    # task could arrive before an earlier one and get misread as
    # belonging to the wrong workflow.
    workflow_id_by_task_id = await_workflow_created_for(Enum.map(tasks, & &1.task_id))

    tasks =
      Enum.map(tasks, fn t ->
        Map.put(t, :workflow_id, Map.fetch!(workflow_id_by_task_id, t.task_id))
      end)

    plan_workflow_ids =
      tasks |> Enum.filter(&(&1.mode == :plan)) |> Enum.map(& &1.workflow_id)

    apply_tasks = Enum.filter(tasks, &(&1.mode == :apply))
    apply_workflow_ids = Enum.map(apply_tasks, & &1.workflow_id)

    # Deliberately populate FailedEventsLog with one real entry, so the
    # "before" and "after" snapshots aren't both trivially [] -- propose
    # an event that's a legal Event struct but an illegal transition for
    # a plan-mode workflow (which never enters :applying), so it's
    # accepted by consensus, durably committed, but rejected by
    # EventStore.append/1's transition check and recorded as failed.
    [poison_workflow_id | _] = plan_workflow_ids

    poison_event = %Event.EffectApplicationComplete{
      id: Id.generate(),
      workflow_id: poison_workflow_id,
      intent_results: [],
      timestamp: DateTime.utc_now()
    }

    assert :ok = Current.Consensus.propose(poison_event)
    :ok = await_failed_event(poison_event.id)

    # 3a/ wait for proposal_validated on every :apply-mode workflow, and
    # decide approve/reject deterministically by position among the
    # apply-mode tasks (not by task index directly, so this generalizes
    # regardless of how many :plan tasks come before it).
    proposal_by_workflow_id = await_proposal_validated_for(apply_workflow_ids)

    {approve_ids, reject_ids} =
      apply_workflow_ids
      |> Enum.with_index()
      |> Enum.split_with(fn {_workflow_id, i} -> rem(i, 2) == 0 end)
      |> then(fn {approve, reject} ->
        {Enum.map(approve, &elem(&1, 0)), Enum.map(reject, &elem(&1, 0))}
      end)

    Enum.each(approve_ids, fn workflow_id ->
      proposal = Map.fetch!(proposal_by_workflow_id, workflow_id)

      assert :ok =
               Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :recovery_test}})
    end)

    Enum.each(reject_ids, fn workflow_id ->
      proposal = Map.fetch!(proposal_by_workflow_id, workflow_id)
      assert :ok = Current.review_proposal(proposal.id, {:reject, %{reviewed_by: :recovery_test}})
    end)

    _ = await_events_for(:workflow_completed, plan_workflow_ids ++ approve_ids)
    _ = await_events_for(:proposal_rejected, reject_ids)

    {:ok, event_entries_before} = EventStore.complete_log_entries()
    events_before = Enum.map(event_entries_before, & &1.event) |> MapSet.new()
    failed_before = FailedEventsLog.all() |> MapSet.new()

    crash_log_and_await_runtime_rebuild()

    {:ok, event_entries_after} = EventStore.complete_log_entries()
    events_after = Enum.map(event_entries_after, & &1.event) |> MapSet.new()
    failed_after = FailedEventsLog.all() |> MapSet.new()

    assert events_before == events_after,
           "expected every canonical event to survive the runtime rebuild, but EventStore " <>
             "came back with #{MapSet.size(events_after)} events instead of the original " <>
             "#{MapSet.size(events_before)} -- EventStore has no WAL-backed reconstruction yet"

    assert failed_before == failed_after,
           "expected FailedEventsLog's contents to survive the runtime rebuild, but it came " <>
             "back with #{MapSet.size(failed_after)} entries instead of the original " <>
             "#{MapSet.size(failed_before)} -- FailedEventsLog has no durable backing"
  end

  defp await_workflow_created_for(task_ids), do: await_workflow_created_for(task_ids, %{})

  defp await_workflow_created_for([], acc), do: acc

  defp await_workflow_created_for(remaining_task_ids, acc) do
    receive do
      {:workflow_created, %Event.WorkflowCreated{task_id: task_id, workflow_id: workflow_id}} ->
        await_workflow_created_for(
          remaining_task_ids -- [task_id],
          Map.put(acc, task_id, workflow_id)
        )
    after
      @receive_timeout -> flunk("did not receive workflow_created for all submitted tasks")
    end
  end

  defp await_proposal_validated_for(workflow_ids),
    do: await_proposal_validated_for(workflow_ids, %{})

  defp await_proposal_validated_for([], acc), do: acc

  defp await_proposal_validated_for(remaining, acc) do
    receive do
      {:proposal_validated,
       %Event.ProposalValidated{workflow_id: workflow_id, proposal: proposal}} ->
        await_proposal_validated_for(
          remaining -- [workflow_id],
          Map.put(acc, workflow_id, proposal)
        )
    after
      @receive_timeout -> flunk("did not receive proposal_validated for all apply-mode workflows")
    end
  end

  defp await_events_for(tag, workflow_ids), do: await_events_for(tag, workflow_ids, [])

  defp await_events_for(_tag, [], acc), do: acc

  defp await_events_for(tag, remaining, acc) do
    receive do
      {^tag, %{workflow_id: workflow_id} = event} ->
        await_events_for(tag, remaining -- [workflow_id], [event | acc])
    after
      @receive_timeout -> flunk("did not receive #{inspect(tag)} for all expected workflows")
    end
  end

  defp await_failed_event(event_id, attempts \\ 100)

  defp await_failed_event(event_id, 0) do
    flunk("#{inspect(event_id)} never showed up in FailedEventsLog")
  end

  defp await_failed_event(event_id, attempts) do
    case FailedEventsLog.get(event_id) do
      {:ok, _event} ->
        :ok

      {:error, :not_found} ->
        Process.sleep(10)
        await_failed_event(event_id, attempts - 1)
    end
  end

  # Resuming workflows after a restart
  test "a workflow waiting for approval is resumed after a runtime rebuild and can still be approved" do
    {:ok, task_id} =
      Current.submit_task(%Request{input: "resume me", context: %{}}, self(), System.tmp_dir!())

    %{^task_id => workflow_id} = await_workflow_created_for([task_id])
    %{^workflow_id => proposal} = await_proposal_validated_for([workflow_id])

    crash_log_and_await_runtime_rebuild()

    assert {:ok, :waiting_for_approval} = Current.get_status(task_id)
    assert :ok = Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :recovery_test}})

    # No listeners survive a rebuild, so observe through the projection.
    :ok = await_status(task_id, :completed)
  end

  test "a workflow interrupted while planning is resumed and completes" do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
    end)

    :ok = Application.put_env(:current, :proposal_builder, Current.BlockingProposalBuilder)

    {:ok, task_id} =
      Current.submit_task(
        %Request{input: "resume me", context: %{}, mode: :plan},
        self(),
        System.tmp_dir!()
      )

    :ok = await_status(task_id, :planning)

    :ok = Application.put_env(:current, :proposal_builder, Current.FakeProposalBuilder)
    crash_log_and_await_runtime_rebuild()

    :ok = await_status(task_id, :planned)
  end

  test "a workflow interrupted mid effect application fails rather than re-applying effects" do
    previous_effect_applicator = Application.fetch_env!(:current, :effect_applicator)
    :ok = Application.put_env(:current, :effect_applicator, Current.BlockingEffectApplicator)

    on_exit(fn ->
      :ok = Application.put_env(:current, :effect_applicator, previous_effect_applicator)
    end)

    {:ok, task_id} =
      Current.submit_task(%Request{input: "resume me", context: %{}}, self(), System.tmp_dir!())

    %{^task_id => workflow_id} = await_workflow_created_for([task_id])
    %{^workflow_id => proposal} = await_proposal_validated_for([workflow_id])

    assert :ok = Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :recovery_test}})
    :ok = await_status(task_id, :applying)

    :ok = Application.put_env(:current, :effect_applicator, Current.EffectApplicator)
    crash_log_and_await_runtime_rebuild()

    :ok = await_status(task_id, :failed)
    assert {:ok, workflow} = Current.get_workflow(task_id)
    assert workflow.error =~ "interrupted"

    events = Current.EventStore.list_by_workflow_id(workflow_id)
    refute Enum.any?(events, &match?(%Event.EffectApplied{}, &1))
  end

  test "an effect applied before a mid-effect-application crash is not re-applied on resume" do
    previous_builder = Application.fetch_env!(:current, :proposal_builder)
    previous_effect_applicator = Application.fetch_env!(:current, :effect_applicator)

    :ok = Application.put_env(:current, :proposal_builder, Current.MultiIntentProposalBuilder)
    :ok = Application.put_env(:current, :effect_applicator, Current.SteppingEffectApplicator)
    Process.register(self(), Current.SteppingEffectApplicator.controller_name())

    on_exit(fn ->
      :ok = Application.put_env(:current, :proposal_builder, previous_builder)
      :ok = Application.put_env(:current, :effect_applicator, previous_effect_applicator)
    end)

    {:ok, task_id} =
      Current.submit_task(
        %Request{input: "step effects", context: %{}},
        self(),
        System.tmp_dir!()
      )

    %{^task_id => workflow_id} = await_workflow_created_for([task_id])
    %{^workflow_id => proposal} = await_proposal_validated_for([workflow_id])
    assert length(proposal.intents) > 1

    [first_intent, second_intent | _] = proposal.intents

    assert :ok =
             Current.review_proposal(proposal.id, {:approve, %{reviewed_by: :stepping_test}})

    # Let exactly the first intent apply, and wait for its EffectApplied to
    # be fully durable before touching anything else -- crashing off of
    # "we sent :step" rather than "it's committed" could race ahead of
    # the commit and defeat the point of this test.
    applicator_pid = assert_awaiting_step(first_intent)
    send(applicator_pid, :step)
    %Event.EffectApplied{} = await_workflow_event(workflow_id, Event.EffectApplied)

    # The second intent must be *blocked*, not merely "not yet applied" --
    # this is what proves the crash below lands genuinely mid-application
    # rather than after everything had already finished.
    _second_applicator_pid = assert_awaiting_step(second_intent)

    events_before = EventStore.list_by_workflow_id(workflow_id)
    effect_applied_before = Enum.filter(events_before, &match?(%Event.EffectApplied{}, &1))

    assert length(effect_applied_before) == 1
    assert hd(effect_applied_before).intent.id == first_intent.id

    crash_log_and_await_runtime_rebuild()

    # Effect application can't safely resume mid-stream: the runtime has
    # no way to know whether the in-flight intent's real-world side effect
    # landed before the crash, so it fails the workflow rather than risk
    # re-running it. See WorkflowOrchestrator.fail_interrupted_effects/1.
    :ok = await_status(task_id, :failed)
    assert {:ok, workflow} = Current.get_workflow(task_id)
    assert workflow.error =~ "interrupted"

    events_after = EventStore.list_by_workflow_id(workflow_id)
    effect_applied_after = Enum.filter(events_after, &match?(%Event.EffectApplied{}, &1))

    # Exactly the one EffectApplied from before the crash: the first
    # intent's effect was not silently re-applied, and the second intent
    # -- never durably recorded as applied -- was not applied for the
    # first time during resume either.
    assert length(effect_applied_after) == 1
    assert hd(effect_applied_after).id == hd(effect_applied_before).id
    assert hd(effect_applied_after).intent.id == first_intent.id

    refute Enum.any?(events_after, &match?(%Event.EffectApplicationComplete{}, &1))
    refute Enum.any?(events_after, &match?(%Event.WorkflowResultAssembled{}, &1))
  end

  defp assert_awaiting_step(expected_intent, timeout \\ 5_000) do
    receive do
      {:awaiting_step, pid, %{id: id}} when id == expected_intent.id ->
        pid
    after
      timeout ->
        flunk(
          "expected SteppingEffectApplicator to be awaiting a step for intent " <>
            "#{expected_intent.id}, but no such message arrived"
        )
    end
  end

  defp await_status(task_id, expected, attempts \\ 200)

  defp await_status(task_id, expected, 0) do
    flunk("expected #{inspect(expected)}, got #{inspect(Current.get_status(task_id))}")
  end

  defp await_status(task_id, expected, attempts) do
    case Current.get_status(task_id) do
      {:ok, ^expected} ->
        :ok

      _ ->
        Process.sleep(10)
        await_status(task_id, expected, attempts - 1)
    end
  end

  defp await_workflow_event(
         workflow_id,
         event_module,
         attempts \\ 200
       )

  defp await_workflow_event(
         workflow_id,
         event_module,
         0
       ) do
    events =
      Current.EventStore.list_by_workflow_id(workflow_id)

    flunk(
      "expected #{inspect(event_module)} for workflow " <>
        "#{workflow_id}; got #{inspect(Enum.map(events, & &1.__struct__))}"
    )
  end

  defp await_workflow_event(
         workflow_id,
         event_module,
         attempts
       ) do
    case Enum.find(
           Current.EventStore.list_by_workflow_id(workflow_id),
           &(&1.__struct__ == event_module)
         ) do
      nil ->
        Process.sleep(10)

        await_workflow_event(
          workflow_id,
          event_module,
          attempts - 1
        )

      event ->
        event
    end
  end

  defp await_workflow_for_task(
         task_id,
         attempts \\ 200
       )

  defp await_workflow_for_task(
         task_id,
         0
       ) do
    flunk("workflow was never created for task #{task_id}")
  end

  defp await_workflow_for_task(
         task_id,
         attempts
       ) do
    case Current.get_workflow(task_id) do
      {:ok, workflow} ->
        workflow

      {:error, :not_found} ->
        Process.sleep(10)

        await_workflow_for_task(
          task_id,
          attempts - 1
        )
    end
  end

  test "a TaskCreated committed before WorkflowCreated is dispatched after runtime recovery" do
    # Prevent the live TaskCreated path from spawning an orchestrator.
    #
    # We deliberately leave the rest of the runtime alive so the event
    # still goes through the real consensus -> WAL -> EventStore path.
    assert :ok =
             Supervisor.terminate_child(
               Current.RuntimeSupervisor,
               Current.TaskDispatcher
             )

    task_id = Id.generate()
    now = DateTime.utc_now()

    task_created = %Event.TaskCreated{
      id: Id.generate(),
      task_id: task_id,
      input: "recover orphan task",
      context: %{},
      mode: :apply,
      project_dir: Current.TestTmp.dir(),
      submitted_at: now,
      timestamp: now
    }

    assert :ok =
             Current.Consensus.propose(task_created)

    # Wait until the consensus-confirmed TaskCreated is canonical before
    # crashing the runtime.
    :ok =
      await_event_in_store(task_created.id)

    {:ok, entries} =
      EventStore.complete_log_entries()

    refute Enum.any?(
             entries,
             fn
               %Current.EventStore.Entry{
                 event: %Event.WorkflowCreated{
                   task_id: ^task_id
                 }
               } ->
                 true

               _ ->
                 false
             end
           )

    crash_log_and_await_runtime_rebuild()

    workflow =
      await_workflow_for_task(task_id)

    assert workflow.task_id == task_id

    # The recovered dispatcher did more than merely recreate the
    # WorkflowCreated event: normal orchestration resumed and reached
    # the review boundary.
    :ok =
      await_status(
        task_id,
        :waiting_for_approval
      )

    events =
      EventStore.list_by_workflow_id(workflow.id)

    assert Enum.any?(
             events,
             &match?(
               %Event.WorkflowCreated{
                 task_id: ^task_id
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Event.ProposalValidated{},
               &1
             )
           )
  end

  defp await_event_in_store(
         event_id,
         attempts \\ 200
       )

  defp await_event_in_store(
         event_id,
         0
       ) do
    flunk("event #{event_id} never became canonical")
  end

  defp await_event_in_store(
         event_id,
         attempts
       ) do
    {:ok, entries} =
      EventStore.complete_log_entries()

    if Enum.any?(
         entries,
         &(&1.event.id == event_id)
       ) do
      :ok
    else
      Process.sleep(10)

      await_event_in_store(
        event_id,
        attempts - 1
      )
    end
  end

  test "a pre-versioning event on disk is upcast when EventStore rebuilds" do
    workflow_id = Id.generate()

    event = %Event.WorkflowCreated{
      id: Id.generate(),
      workflow_id: workflow_id,
      task_id: Id.generate(),
      mode: :apply,
      timestamp: DateTime.utc_now()
    }

    # What this event looked like on disk before :version existed.
    pre_versioning = Map.delete(event, :version)
    assert :ok = Current.Consensus.propose(pre_versioning)
    :ok = await_event_in_store(event.id)

    # Log is byte-faithful: it hands back exactly what was stored.
    assert {:ok, ^pre_versioning} = Log.get(event.id)

    restart_application()

    assert {:ok, ^pre_versioning} = Log.get(event.id)

    assert [%Event.WorkflowCreated{version: 1} = rebuilt] =
             EventStore.list_by_workflow_id(workflow_id)

    assert rebuilt == event
  end
end
