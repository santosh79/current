defmodule Current.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Current.CLI
  alias Current.Event

  # Runs a plan through the CLI (in-process) and returns its output.
  defp plan!(prompt \\ "add email validation") do
    capture_io(fn ->
      assert CLI.run(["plan", prompt, "--dir", System.tmp_dir!()]) == 0
    end)
  end

  # Runs an apply-mode task through the CLI; it stops at approval.
  defp run!(prompt \\ "add email validation") do
    capture_io(fn ->
      assert CLI.run(["run", prompt, "--dir", System.tmp_dir!()]) == 0
    end)
  end

  defp id_after(output, label) do
    [_, id] = Regex.run(~r/#{label}\s+(sha256:[0-9a-f]+)/, output)
    id
  end

  describe "parse/1" do
    test "plan defaults --dir to the current directory" do
      assert CLI.parse(["plan", "Add rate limiting"]) == {:plan, "Add rate limiting", "."}
    end

    test "--dir may come before or after the prompt" do
      assert CLI.parse(["plan", "Add", "--dir", "x"]) == {:plan, "Add", "x"}
      assert CLI.parse(["plan", "-d", "x", "Add"]) == {:plan, "Add", "x"}
    end

    test "inspector commands take exactly one id" do
      assert CLI.parse(["events", "sha256:ab12"]) == {:events, "sha256:ab12"}
      assert CLI.parse(["proposal", "ab12"]) == {:proposal, "ab12"}
      assert CLI.parse(["artifact", "ab12"]) == {:artifact, "ab12"}
      assert {:error, _} = CLI.parse(["events"])
      assert {:error, _} = CLI.parse(["artifact", "a", "b"])
    end

    test "run takes the same arguments as plan" do
      assert CLI.parse(["run", "Add rate limiting"]) == {:run, "Add rate limiting", "."}
      assert CLI.parse(["run", "Add", "--dir", "x"]) == {:run, "Add", "x"}
      assert CLI.parse(["run", "-d", "x", "Add"]) == {:run, "Add", "x"}
      assert {:error, _} = CLI.parse(["run"])
      assert {:error, _} = CLI.parse(["run", "--nope", "x"])
    end

    test "approve and reject take one proposal id and an optional message" do
      assert CLI.parse(["approve", "ab12"]) == {:approve, "ab12", "Approved via the current CLI"}
      assert CLI.parse(["approve", "ab12", "-m", "lgtm"]) == {:approve, "ab12", "lgtm"}
      assert CLI.parse(["approve", "--message", "lgtm", "ab12"]) == {:approve, "ab12", "lgtm"}
      assert CLI.parse(["reject", "ab12"]) == {:reject, "ab12", "Rejected via the current CLI"}
      assert CLI.parse(["reject", "ab12", "-m", "not yet"]) == {:reject, "ab12", "not yet"}

      for command <- ["approve", "reject"] do
        assert {:error, _} = CLI.parse([command])
        assert {:error, _} = CLI.parse([command, "a", "b"])
        assert {:error, _} = CLI.parse([command, "ab12", "-m", "  "])
        assert {:error, _} = CLI.parse([command, "ab12", "--nope"])
      end
    end

    test "apply takes exactly one proposal id and no message" do
      assert CLI.parse(["apply", "ab12"]) == {:apply, "ab12"}
      assert {:error, _} = CLI.parse(["apply"])
      assert {:error, _} = CLI.parse(["apply", "a", "b"])
      assert {:error, _} = CLI.parse(["apply", "ab12", "-m", "lgtm"])
    end

    test "status takes no arguments" do
      assert CLI.parse(["status"]) == :status
    end

    test "usage errors" do
      assert {:error, _} = CLI.parse(["plan"])
      assert {:error, _} = CLI.parse(["plan", "--nope", "x"])
      assert {:error, _} = CLI.parse(["frobnicate"])
      assert CLI.parse([]) == :help
    end
  end

  describe "plan" do
    test "submits a plan-mode task and renders its canonical events" do
      output = plan!()

      assert output =~ "PROPOSED"
      assert output =~ "FilePatch"
      assert output =~ "✓ Proposal validated"
      assert output =~ "✓ Workflow completed"
      assert output =~ "MODE: PLAN\n0 effects executed."
      assert output =~ "current events   sha256:"
      refute output =~ "✓ FilePatch"
    end

    test "a proposal production failure exits 1 and says why" do
      previous = Application.fetch_env!(:current, :proposal_builder)
      Application.put_env(:current, :proposal_builder, Current.ErrorReturningProposalBuilder)
      on_exit(fn -> Application.put_env(:current, :proposal_builder, previous) end)

      output =
        capture_io(fn ->
          assert CLI.run(["plan", "anything", "--dir", System.tmp_dir!()]) == 1
        end)

      assert output =~ "✗ Proposal production failed"
      assert output =~ "rate_limited"
    end

    test "an invalid --dir is rejected before anything is recorded" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert CLI.run(["plan", "x", "--dir", "/definitely/not/here"]) == 1
          end)
        end)

      assert stderr =~ "invalid project directory"
    end

    test "an unreachable runtime is reported, and nothing is submitted" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["plan", "x"], fn -> {:error, :runtime_unavailable} end) == 1
        end)

      assert stderr =~ "runtime is not running"
      assert stderr =~ "bin/current-server"
    end

    test "transport failures mid-command come back as errors, not crashes" do
      failing = fn ->
        {:ok,
         %Current.CLI.Client{
           node: :current@localhost,
           call: fn _, _ -> :erlang.error({:erpc, :noconnection}) end
         }}
      end

      stderr = capture_io(:stderr, fn -> assert CLI.run(["events", "abcd1234"], failing) == 1 end)
      assert stderr =~ "runtime is not running at current@localhost"
    end

    test "the plan output tells you how to follow the workflow after detaching" do
      assert plan!() =~ "Ctrl-C detaches"
    end
  end

  describe "run" do
    test "creates an apply-mode workflow that halts at approval without applying anything" do
      output = run!()

      assert output =~ "mode     apply"
      assert output =~ "✓ Proposal validated"
      assert output =~ "MODE: APPLY\n0 effects executed."
      assert output =~ "Waiting for approval. Nothing has been applied."
      assert output =~ "current approve sha256:"
      refute output =~ "✓ Workflow completed"

      {:ok, view} = Current.Inspector.workflow(id_after(output, "task"))
      assert view.mode == :apply
      assert view.status == :waiting_for_approval
      refute view.terminal

      refute Enum.any?(view.entries, &match?(%{event: %Event.ProposalApproved{}}, &1))
      refute Enum.any?(view.entries, &match?(%{event: %Event.EffectApplicationStarted{}}, &1))
    end

    test "the workflow stays halted: nothing moves it on without an approval" do
      task_id = run!() |> id_after("task")
      {:ok, before} = Current.Inspector.workflow(task_id)

      Process.sleep(500)

      {:ok, later} = Current.Inspector.workflow(task_id)
      assert later.status == :waiting_for_approval
      assert length(later.entries) == length(before.entries)
    end
  end

  # The full id of the proposal a `run` output names.
  defp proposal_in(output), do: id_after(output, "current approve")

  defp approve!(proposal_id, args \\ []) do
    capture_io(fn -> assert CLI.run(["approve", proposal_id | args]) == 0 end)
  end

  defp proposal_approved(view) do
    Enum.find_value(view.entries, fn
      %{event: %Event.ProposalApproved{} = event} -> event
      _ -> nil
    end)
  end

  defp application_started?(view),
    do: Enum.any?(view.entries, &match?(%{event: %Event.EffectApplicationStarted{}}, &1))

  describe "approve" do
    test "records the approval and message, and applies nothing" do
      output = run!()
      task_id = id_after(output, "task")
      proposal_id = proposal_in(output)

      approved = approve!(proposal_id, ["-m", "lgtm, ship it"])

      assert approved =~ "✓ Approved #{proposal_id}"
      assert approved =~ "message  lgtm, ship it"

      assert approved =~
               "Nothing has been applied. Apply it with:\n  current apply #{proposal_id}"

      Process.sleep(300)
      {:ok, view} = Current.Inspector.workflow(task_id)
      assert view.status == :approved
      refute application_started?(view)

      assert %Event.ProposalApproved{metadata: metadata} = proposal_approved(view)
      assert %{message: "lgtm, ship it", via: :cli, reviewed_by: reviewer} = metadata
      assert is_binary(reviewer)
    end

    test "without -m, a default message is recorded" do
      output = run!()
      approve!(proposal_in(output))

      {:ok, view} = Current.Inspector.workflow(id_after(output, "task"))
      assert proposal_approved(view).metadata.message == "Approved via the current CLI"
    end

    test "a proposal can only be approved once" do
      proposal_id = run!() |> proposal_in()
      approve!(proposal_id)

      stderr = capture_io(:stderr, fn -> assert CLI.run(["approve", proposal_id]) == 1 end)
      assert stderr =~ "can't be approved: its workflow is approved, not waiting for approval"
    end

    test "refuses a proposal from a plan-mode workflow and leaves it untouched" do
      output = plan!()
      proposal_id = id_after(output, "current proposal")

      stderr = capture_io(:stderr, fn -> assert CLI.run(["approve", proposal_id]) == 1 end)
      assert stderr =~ "plan-mode workflow"

      {:ok, view} = Current.Inspector.workflow(id_after(output, "task"))
      assert view.status == :planned
      refute proposal_approved(view)
    end
  end

  describe "reject" do
    test "rejects a waiting proposal, which then can't be approved or applied" do
      output = run!()
      proposal_id = proposal_in(output)

      rejected =
        capture_io(fn ->
          assert CLI.run(["reject", proposal_id, "-m", "don't change auth yet"]) == 0
        end)

      assert rejected =~ "✓ Rejected #{proposal_id}"

      {:ok, view} = Current.Inspector.workflow(id_after(output, "task"))
      assert view.status == :rejected

      assert %{event: %Event.ProposalRejected{metadata: %{message: "don't change auth yet"}}} =
               Enum.find(view.entries, &match?(%{event: %Event.ProposalRejected{}}, &1))

      stderr = capture_io(:stderr, fn -> assert CLI.run(["approve", proposal_id]) == 1 end)
      assert stderr =~ "its workflow is rejected"

      stderr = capture_io(:stderr, fn -> assert CLI.run(["apply", proposal_id]) == 1 end)
      assert stderr =~ "can't be applied: its workflow is rejected, not approved"
    end

    test "an approved proposal can't be rejected" do
      proposal_id = run!() |> proposal_in()
      approve!(proposal_id)

      stderr = capture_io(:stderr, fn -> assert CLI.run(["reject", proposal_id]) == 1 end)
      assert stderr =~ "can't be rejected: its workflow is approved"
    end
  end

  describe "apply" do
    test "applies an approved proposal and follows it to completion" do
      output = run!()
      task_id = id_after(output, "task")
      proposal_id = proposal_in(output)
      approve!(proposal_id)

      applied = capture_io(fn -> assert CLI.run(["apply", proposal_id]) == 0 end)

      assert applied =~ "✓ Applying #{proposal_id}"
      assert applied =~ "✓ Proposal approved"
      assert applied =~ "✓ Workflow completed"
      assert applied =~ "MODE: APPLY\n1 effect executed."

      {:ok, view} = Current.Inspector.workflow(task_id)
      assert view.status == :completed
      assert application_started?(view)
    end

    test "a proposal that hasn't been approved can't be applied, and nothing runs" do
      output = run!()
      proposal_id = proposal_in(output)

      stderr = capture_io(:stderr, fn -> assert CLI.run(["apply", proposal_id]) == 1 end)

      assert stderr =~
               "hasn't been approved yet. Approve it first:\n  current approve #{proposal_id}"

      {:ok, view} = Current.Inspector.workflow(id_after(output, "task"))
      assert view.status == :waiting_for_approval
      refute application_started?(view)
    end

    test "a proposal can only be applied once" do
      proposal_id = run!() |> proposal_in()
      approve!(proposal_id)
      capture_io(fn -> assert CLI.run(["apply", proposal_id]) == 0 end)

      stderr = capture_io(:stderr, fn -> assert CLI.run(["apply", proposal_id]) == 1 end)
      assert stderr =~ "can't be applied: its workflow is completed, not approved"
    end

    test "refuses a proposal from a plan-mode workflow" do
      proposal_id = plan!() |> id_after("current proposal")

      stderr = capture_io(:stderr, fn -> assert CLI.run(["apply", proposal_id]) == 1 end)
      assert stderr =~ "plan-mode workflow; only proposals from `current run` can be applied"
    end

    test "unknown proposal ids" do
      for command <- ["approve", "reject", "apply"] do
        assert capture_io(:stderr, fn ->
                 assert CLI.run([command, "sha256:ffffffffffff0000"]) == 1
               end) =~ "no proposal matches"
      end
    end
  end

  describe "events" do
    test "lists the workflow's events with positions, TaskCreated first" do
      workflow_id = plan!() |> id_after("current events")

      output = capture_io(fn -> assert CLI.run(["events", workflow_id]) == 0 end)

      names =
        Regex.scan(~r/^\d+\s+(\w+)/m, output, capture: :all_but_first) |> List.flatten()

      assert names == [
               "TaskCreated",
               "WorkflowCreated",
               "ProposalProductionStarted",
               "ProposalProduced",
               "ProposalValidated",
               "WorkflowCompleted"
             ]

      positions = Regex.scan(~r/^(\d+)\s/m, output, capture: :all_but_first) |> List.flatten()
      assert positions == Enum.sort_by(positions, &String.to_integer/1)
      assert output =~ "Status    planned (plan mode)"
    end

    test "accepts the task id and a bare hex prefix" do
      output = plan!()
      "sha256:" <> task_hex = id_after(output, "task")

      assert capture_io(fn -> assert CLI.run(["events", String.slice(task_hex, 0, 10)]) == 0 end) =~
               "WorkflowCompleted"
    end

    test "unknown and too-short ids" do
      assert capture_io(:stderr, fn ->
               assert CLI.run(["events", "sha256:ffffffffffff0000"]) == 1
             end) =~
               "no workflow matches"

      assert capture_io(:stderr, fn -> assert CLI.run(["events", "ab"]) == 1 end) =~ "too short"
    end
  end

  describe "proposal and artifact" do
    test "a proposal shows every intent with full artifact ids, and the diff is readable" do
      proposal_id = plan!() |> id_after("current proposal")

      output = capture_io(fn -> assert CLI.run(["proposal", proposal_id]) == 0 end)

      assert output =~ "Status    planned (plan mode)"
      assert output =~ "1. FilePatch"
      assert output =~ "invalid emails are rejected"
      diff_id = id_after(output, "diff")
      assert byte_size(diff_id) == byte_size("sha256:") + 64

      diff =
        capture_io(fn -> assert CLI.run(["artifact", Current.CLI.Render.short(diff_id)]) == 0 end)

      assert diff == elem(Current.BlobStore.read(diff_id), 1)
      assert diff =~ "+  def validate_email(email)"
    end

    test "artifact bytes pass through unchanged" do
      contents = "naïve ✓ \u00e9\n"
      {:ok, id} = Current.BlobStore.put(contents)

      assert capture_io(fn -> assert CLI.run(["artifact", id]) == 0 end) == contents
    end
  end

  describe "status" do
    test "reports the runtime and its model configuration" do
      output = capture_io(fn -> assert CLI.run(["status"]) == 0 end)

      assert output =~ "runtime ready"
      assert output =~ "WAL head"
      assert output =~ "builder   Current.FakeProposalBuilder"
    end
  end
end
