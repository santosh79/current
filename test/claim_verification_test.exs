defmodule Current.ClaimVerificationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Current.{CLI, EffectResult, Event, EventStore, Intent, Request}

  @receive_timeout 5_000

  setup do
    previous = Application.fetch_env!(:current, :proposal_builder)
    :ok = Application.put_env(:current, :proposal_builder, Current.ClaimProposalBuilder)
    on_exit(fn -> Application.put_env(:current, :proposal_builder, previous) end)
  end

  # Submits an apply-mode task, approves its proposal, and waits for the
  # workflow to end. Returns the workflow's committed events.
  defp apply_to_end(input) do
    {:ok, task_id} =
      Current.submit_task(%Request{input: input, context: %{}}, self(), System.tmp_dir!())

    assert_receive {:workflow_created,
                    %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}},
                   @receive_timeout

    assert_receive {:proposal_validated,
                    %Event.ProposalValidated{workflow_id: ^workflow_id, proposal: proposal}},
                   @receive_timeout

    :ok = Current.TestApproval.approve_and_apply(proposal.id, %{reviewed_by: :claim_test})

    receive do
      {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id}} -> :ok
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id}} -> :ok
    after
      @receive_timeout -> flunk("workflow did not finish")
    end

    {task_id, EventStore.list_by_workflow_id(workflow_id)}
  end

  defp claim_results(events) do
    for %Event.EffectApplied{result: %EffectResult.Claim{} = claim} <- events, do: claim
  end

  describe "runtime" do
    test "a claim that holds lets the workflow complete" do
      {task_id, events} = apply_to_end("tests pass")

      assert [%EffectResult.Claim{verified: true}] = claim_results(events)
      assert {:ok, :completed} = Current.get_status(task_id)
      refute Enum.any?(events, &match?(%Event.EffectFailed{}, &1))
    end

    test "a claim that doesn't hold fails the workflow and keeps its evidence" do
      {task_id, events} = apply_to_end("tests fail")

      # The claim's result, with the evidence that disproved it, is recorded...
      assert [%EffectResult.Claim{verified: false, reason: reason, evidence: evidence}] =
               claim_results(events)

      assert reason == "command exited with 1, expected 0"
      assert evidence.condition == :exit_code_equals

      # ...and then fails the workflow, right after it.
      names = Enum.map(events, & &1.__struct__)

      claim_at =
        Enum.find_index(events, &match?(%Event.EffectApplied{intent: %Intent.Claim{}}, &1))

      assert Enum.at(names, claim_at + 1) == Event.EffectFailed
      assert List.last(names) == Event.WorkflowFailed

      assert %Event.EffectFailed{intent: %Intent.Claim{}, reason: failed_reason} =
               Enum.find(events, &match?(%Event.EffectFailed{}, &1))

      assert failed_reason == "claim not verified: command exited with 1, expected 0"

      assert {:ok, :failed} = Current.get_status(task_id)
      assert {:ok, workflow} = Current.get_workflow(task_id)
      assert workflow.error =~ "claim not verified"
    end

    test "nothing after a failed claim is applied" do
      {_task_id, events} = apply_to_end("tests fail")

      refute Enum.any?(events, &match?(%Event.EffectApplied{intent: %Intent.Report{}}, &1))
      refute Enum.any?(events, &match?(%Event.EffectApplicationComplete{}, &1))
      refute Enum.any?(events, &match?(%Event.WorkflowCompleted{}, &1))
    end
  end

  describe "CLI" do
    defp run_and_apply(input, expected_exit) do
      run_out =
        capture_io(fn ->
          assert CLI.run(["run", input, "--dir", System.tmp_dir!()]) == 0
        end)

      [_, task_id] = Regex.run(~r/task\s+(sha256:[0-9a-f]+)/, run_out)
      [_, proposal_id] = Regex.run(~r/current approve (sha256:[0-9a-f]+)/, run_out)
      capture_io(fn -> assert CLI.run(["approve", proposal_id]) == 0 end)

      apply_out =
        capture_io(fn -> assert CLI.run(["apply", proposal_id]) == expected_exit end)

      events_out = capture_io(fn -> assert CLI.run(["events", task_id]) == 0 end)
      {apply_out, events_out}
    end

    defp position_of(events_out, pattern) do
      [_, pos] = Regex.run(~r/^(\d+)\s+EffectApplied\s+\S+\s+#{pattern}/m, events_out)
      pos
    end

    test "events show a command's exit code and a claim's evidence by position" do
      {_apply_out, events_out} = run_and_apply("tests pass", 0)

      assert events_out =~ "RunCommand sh -c exit 0 · exit 0"
      command_pos = position_of(events_out, "RunCommand")

      assert events_out =~
               ~s{Claim ✓ ##{command_pos} exit 0 (expected 0) · "the test suite passes"}
    end

    test "apply lists each claim with the evidence it was checked against" do
      {apply_out, _events_out} = run_and_apply("tests pass", 0)

      assert apply_out =~ """
             Claim checks
               ✓ "the test suite passes"
                   RunCommand sh -c exit 0 · exit 0 (expected 0)
             """

      assert apply_out =~ "3 effects executed · 1 claim verified."
      assert apply_out =~ "✓ Workflow completed"
    end

    test "a claim that doesn't hold is shown as failed, and apply exits 1" do
      {apply_out, events_out} = run_and_apply("tests fail", 1)

      assert apply_out =~ ~s(✗ "the test suite passes")
      assert apply_out =~ "RunCommand sh -c exit 1 · exit 1 (expected 0)"
      assert apply_out =~ "2 effects executed · 1 claim not verified."

      assert apply_out =~
               "✗ Workflow failed: claim not verified: command exited with 1, expected 0"

      command_pos = position_of(events_out, "RunCommand")
      assert events_out =~ "Claim ✗ ##{command_pos} exit 1 (expected 0)"
      assert events_out =~ ~r/EffectFailed\s+\S+\s+claim not verified: command exited with 1/
      assert events_out =~ "Status    failed (apply mode)"
    end
  end

  describe "rendering without a runtime" do
    alias Current.CLI.Render
    alias Current.EventStore.Entry

    defp view(events) do
      now = DateTime.utc_now()

      entries =
        events
        |> Enum.with_index(1)
        |> Enum.map(fn {event, pos} -> %Entry{position: pos, event: event, inserted_at: now} end)

      %{
        entries: entries,
        workflow_id: "sha256:" <> String.duplicate("a", 64),
        task: nil,
        status: :applying,
        mode: :apply
      }
    end

    defp applied(intent, result) do
      %Event.EffectApplied{
        id: Current.Id.generate(),
        workflow_id: "w",
        intent: intent,
        result: result,
        timestamp: DateTime.utc_now()
      }
    end

    test "grep claims show the observed match count against the condition" do
      grep = %Intent.Grep{id: "g", proposal_id: "p", pattern: "minLength", paths: ["lib/auth.ts"]}

      grep_result = %EffectResult.Grep{
        matches_artifact_id: "m",
        match_count: 2,
        searched_artifact_ids: []
      }

      claim = %Intent.Claim{id: "c", proposal_id: "p", statement: "length is enforced"}

      claim_result = %EffectResult.Claim{
        verified: true,
        statement: "length is enforced",
        reason: "grep produced 2 match(es), expected more than 0",
        evidence: %{source_intent_id: "g", condition: :match_count_greater_than, value: 0}
      }

      out = Render.events(view([applied(grep, grep_result), applied(claim, claim_result)]))

      assert out =~ ~s(Grep "minLength" in lib/auth.ts · 2 matches)
      assert out =~ ~s{Claim ✓ #1 2 matches (expected > 0) · "length is enforced"}
    end

    test "a claim whose source isn't in the history falls back to the recorded reason" do
      claim = %Intent.Claim{id: "c", proposal_id: "p", statement: "s"}

      claim_result = %EffectResult.Claim{
        verified: false,
        statement: "s",
        reason: "command exited with 2, expected 0",
        evidence: %{source_intent_id: "missing", condition: :exit_code_equals, value: 0}
      }

      out = Render.events(view([applied(claim, claim_result)]))
      assert out =~ ~s(Claim ✗ command exited with 2, expected 0 · "s")
    end
  end
end
