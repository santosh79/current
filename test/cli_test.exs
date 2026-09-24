defmodule Current.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Current.CLI

  # Runs a plan through the CLI (in-process) and returns its output.
  defp plan!(prompt \\ "add email validation") do
    capture_io(fn ->
      assert CLI.run(["plan", prompt, "--dir", System.tmp_dir!()]) == 0
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
