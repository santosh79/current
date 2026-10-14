defmodule Current.CLITest do
  @moduledoc """
  The CLI's own job: turning arguments into commands, and runtime
  answers into output and exit codes. How workflows behave is tested
  through Current.submit_task/3 (test/e2e) and Current.RPC
  (test/rpc_test.exs), not again here.

  Commands run in-process against the test application (CLI.run/1
  defaults to a local client).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Current.TestHelpers, only: [model: 0, use_proposal_builder: 1]

  alias Current.CLI

  defp task_args(command, prompt \\ "add email validation"),
    do: [command, prompt, "--dir", System.tmp_dir!(), "--model", model()]

  # Runs a command expecting `exit_code`; returns what it printed to stdout.
  defp cli!(args, exit_code \\ 0) do
    capture_io(fn -> assert CLI.run(args) == exit_code end)
  end

  # Runs a command expecting it to fail with `exit_code`; returns its stderr.
  defp cli_error(args, exit_code \\ 1) do
    capture_io(:stderr, fn -> capture_io(fn -> assert CLI.run(args) == exit_code end) end)
  end

  defp id_after(output, label) do
    [_, id] = Regex.run(~r/#{label}\s+(sha256:[0-9a-f]+)/, output)
    id
  end

  describe "parse/1" do
    test "plan defaults --dir to the current directory" do
      assert CLI.parse(["plan", "Add rate limiting", "--model", "openai:gpt-5.6"]) ==
               {:plan, "Add rate limiting", ".", "openai:gpt-5.6"}
    end

    test "--dir and --model may come before or after the prompt" do
      assert CLI.parse(["plan", "Add", "--dir", "x", "--model", "m"]) == {:plan, "Add", "x", "m"}
      assert CLI.parse(["plan", "-d", "x", "--model", "m", "Add"]) == {:plan, "Add", "x", "m"}
    end

    test "plan and run require --model, and say where to find one" do
      for command <- ["plan", "run"] do
        assert {:error, message, hint} = CLI.parse([command, "Add"])
        assert message =~ "--model"
        assert hint =~ "current models"

        assert {:error, _message, _hint} = CLI.parse([command, "Add", "--model", "  "])
      end
    end

    test "inspector commands take exactly one id" do
      assert CLI.parse(["events", "sha256:ab12"]) == {:events, "sha256:ab12"}
      assert CLI.parse(["proposal", "ab12"]) == {:proposal, "ab12"}
      assert CLI.parse(["artifact", "ab12"]) == {:artifact, "ab12"}
      assert {:error, _} = CLI.parse(["events"])
      assert {:error, _} = CLI.parse(["artifact", "a", "b"])
    end

    test "run takes the same arguments as plan" do
      assert CLI.parse(["run", "Add rate limiting", "--model", "m"]) ==
               {:run, "Add rate limiting", ".", "m"}

      assert CLI.parse(["run", "Add", "--dir", "x", "--model", "m"]) == {:run, "Add", "x", "m"}
      assert CLI.parse(["run", "-d", "x", "--model", "m", "Add"]) == {:run, "Add", "x", "m"}
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

    test "review takes one proposal id and its output options" do
      assert {:review, "ab12", %{format: :markdown, max_lines: 200, raw: false}} =
               CLI.parse(["review", "ab12"])

      assert {:review, "ab12", %{format: :json, max_lines: 5, raw: true}} =
               CLI.parse(["review", "--json", "--max-lines", "5", "--raw", "ab12"])

      assert {:error, _} = CLI.parse(["review"])
      assert {:error, _} = CLI.parse(["review", "a", "b"])
      assert {:error, _} = CLI.parse(["review", "ab12", "--max-lines", "0"])
      assert {:error, _} = CLI.parse(["review", "ab12", "--nope"])
    end
  end

  describe "plan" do
    test "prints the task, its model, the validated proposal and how to look further" do
      output = cli!(task_args("plan"))

      assert output =~ ~r/model\s+#{Regex.escape(model())}/
      assert output =~ "Ctrl-C detaches"
      assert output =~ "PROPOSED"
      assert output =~ "FilePatch"
      assert output =~ "✓ Proposal validated"
      assert output =~ "✓ Workflow completed"
      assert output =~ "MODE: PLAN\n0 effects executed."
      assert output =~ "current events   sha256:"
    end

    test "a workflow that fails exits 1 and says why" do
      use_proposal_builder(Current.ErrorReturningProposalBuilder)

      output = cli!(task_args("plan"), 1)

      assert output =~ "✗ Proposal production failed"
      assert output =~ "rate_limited"
    end

    test "without --model nothing is submitted: exit 2, pointing at `current models`" do
      stderr = cli_error(["plan", "x", "--dir", System.tmp_dir!()], 2)

      assert stderr =~ "plan needs --model"
      assert stderr =~ "current models"
    end

    test "a model the runtime doesn't list is refused" do
      stderr = cli_error(["plan", "x", "--dir", System.tmp_dir!(), "--model", "openai:nope"])

      assert stderr =~ "unknown model openai:nope"
      assert stderr =~ "current models"
    end

    test "an invalid --dir is refused" do
      stderr = cli_error(["plan", "x", "--dir", "/definitely/not/here", "--model", model()])
      assert stderr =~ "invalid project directory"
    end
  end

  describe "run, review, approve, apply" do
    test "run stops at approval; approve applies nothing; apply follows the workflow to its end" do
      ran = cli!(task_args("run"))

      assert ran =~ "mode     apply"
      assert ran =~ "Waiting for approval. Nothing has been applied."
      assert ran =~ ~r/current review sha256:[0-9a-f]{12}\n  current approve sha256:/
      refute ran =~ "✓ Workflow completed"

      proposal_id = id_after(ran, "current approve")

      review = cli!(["review", proposal_id])
      assert review =~ "# Proposal review"
      assert review =~ "+  def validate_email(email)"

      # Not approved yet, so it can't be applied.
      assert cli_error(["apply", proposal_id]) =~
               "hasn't been approved yet. Approve it first:\n  current approve #{proposal_id}"

      approved = cli!(["approve", proposal_id, "-m", "lgtm, ship it"])
      assert approved =~ "✓ Approved #{proposal_id}"
      assert approved =~ "message  lgtm, ship it"

      assert approved =~
               "Nothing has been applied. Apply it with:\n  current apply #{proposal_id}"

      applied = cli!(["apply", proposal_id])
      assert applied =~ "✓ Applying #{proposal_id}"
      assert applied =~ "✓ Workflow completed"
      assert applied =~ "MODE: APPLY\n1 effect executed."

      assert cli_error(["apply", proposal_id]) =~
               "can't be applied: its workflow is completed, not approved"
    end

    test "reject ends the proposal, which then can't be approved" do
      proposal_id = cli!(task_args("run")) |> id_after("current approve")

      assert cli!(["reject", proposal_id, "-m", "not yet"]) =~ "✓ Rejected #{proposal_id}"
      assert cli_error(["approve", proposal_id]) =~ "its workflow is rejected"
    end

    test "a plan-mode proposal is refused, in words" do
      proposal_id = cli!(task_args("plan")) |> id_after("current proposal")

      assert cli_error(["approve", proposal_id]) =~ "plan-mode workflow"

      assert cli_error(["apply", proposal_id]) =~
               "plan-mode workflow; only proposals from `current run` can be applied"
    end

    test "review --json is machine-readable" do
      proposal_id = cli!(task_args("plan")) |> id_after("current proposal")
      doc = cli!(["review", proposal_id, "--json"]) |> JSON.decode!()

      assert doc["schema"] == "current.review/v1"
      assert [%{"type" => "FilePatch", "artifact" => %{"truncated" => false}}] = doc["intents"]
    end
  end

  describe "events, proposal, artifact" do
    test "events lists the workflow's history in order, by id or prefix" do
      planned = cli!(task_args("plan"))
      "sha256:" <> task_hex = id_after(planned, "task")

      output = cli!(["events", String.slice(task_hex, 0, 10)])

      names = Regex.scan(~r/^\d+\s+(\w+)/m, output, capture: :all_but_first) |> List.flatten()

      assert names == [
               "TaskCreated",
               "WorkflowCreated",
               "ProposalProductionStarted",
               "ProposalProduced",
               "ProposalValidated",
               "WorkflowCompleted"
             ]

      assert output =~ "Status    planned (plan mode)"
    end

    test "proposal shows its intents, and artifact prints an artifact's exact bytes" do
      proposal_id = cli!(task_args("plan")) |> id_after("current proposal")

      output = cli!(["proposal", proposal_id])
      assert output =~ "Status    planned (plan mode)"
      assert output =~ "1. FilePatch"

      diff_id = id_after(output, "diff")
      diff = cli!(["artifact", Current.CLI.Render.short(diff_id)])

      assert {:ok, ^diff} = Current.BlobStore.read(diff_id)
      assert diff =~ "+  def validate_email(email)"
    end

    test "artifact bytes pass through unchanged" do
      contents = "naïve ✓ \u00e9\n"
      {:ok, id} = Current.BlobStore.put(contents)

      assert cli!(["artifact", id]) == contents
    end

    test "ids that match nothing, or are too short, are reported" do
      unknown = "sha256:ffffffffffff0000"

      assert cli_error(["events", unknown]) =~ "no workflow matches"
      assert cli_error(["events", "ab"]) =~ "too short"

      for command <- ["proposal", "review", "approve", "reject", "apply"] do
        assert cli_error([command, unknown]) =~ "no proposal matches"
      end
    end
  end

  describe "status and models" do
    test "status reports the runtime and its configuration" do
      output = cli!(["status"])

      assert output =~ "runtime ready"
      assert output =~ "WAL head"
      assert output =~ "builder   Current.FakeProposalBuilder"
    end

    test "models lists the catalog, one per line" do
      assert cli!(["models"]) |> String.split("\n", trim: true) == Current.RPC.models()
    end
  end

  describe "a runtime that can't be reached" do
    test "is reported, with how to start it" do
      unreachable = fn -> {:error, :runtime_unavailable} end

      stderr = capture_io(:stderr, fn -> assert CLI.run(task_args("plan"), unreachable) == 1 end)

      assert stderr =~ "runtime is not running"
      assert stderr =~ "bin/current-server"
    end

    test "a connection lost mid-command is an error, not a crash" do
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
  end
end
