defmodule Current.E2E.LLMProposalTest do
  @moduledoc """
  The real proposal builder (Current.LLMProposalBuilder) end to end, with
  only the model faked: the request's model resolves to a test catalog
  client, which answers with whatever FakeLLMClient.set_response/1 was
  given. Whatever the model says, the workflow ends in a recorded outcome.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{Event, FakeLLMClient, Intent, LLMProposalBuilder, Observation}

  setup do
    use_proposal_builder(LLMProposalBuilder)
  end

  # Plan mode against this repository's own directory as the project.
  defp submit_with_response(response) do
    FakeLLMClient.set_response(response)
    {:ok, task_id} = Current.submit_task(request(mode: :plan), self())
    {task_id, await_workflow_created(task_id)}
  end

  defp production_error(workflow_id) do
    %Event.ProposalProductionFailed{error: error} =
      await(:proposal_production_failed, workflow_id)

    error
  end

  test "a well-formed model response completes as :planned" do
    raw = ~s({
      "justification": "add email validation",
      "intents": [
        {"ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"]},
        {"type": "claim", "statement": "tests pass",
         "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}}
      ]
    })

    {task_id, workflow_id} = submit_with_response({:ok, raw})

    %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)
    assert length(proposal.intents) == 2

    await(:proposal_validated, workflow_id)
    await(:workflow_completed, workflow_id)

    assert {:ok, final} = Current.get_workflow(task_id)
    assert final.status == :planned
    assert final.mode == :plan
    assert final.result == nil
  end

  test "an undecodable response fails production at the decode stage, keeping the raw output" do
    {task_id, workflow_id} = submit_with_response({:ok, "not json at all {{{"})

    error = production_error(workflow_id)
    assert error.stage == :decode
    assert error.raw_output_blob_id != nil

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end

  test "a well-formed but semantically invalid response fails validation, not production" do
    raw = ~s({"intents": [{"type": "claim", "statement": "no evidence given"}]})
    {task_id, workflow_id} = submit_with_response({:ok, raw})

    await(:proposal_produced, workflow_id)

    %Event.ProposalValidationFailed{error: error} =
      await(:proposal_validation_failed, workflow_id)

    assert error.reason =~ "requires evidence"

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end

  test "a client error fails production at the connection stage" do
    {task_id, workflow_id} = submit_with_response({:error, :econnrefused})

    assert production_error(workflow_id).stage == :connection

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end

  describe "a model that asks to see files first" do
    @secret "hunter2"

    @observe_signup ~s({"observe": [
      {"reason": "find the modules", "intent": {"type": "glob", "pattern": "lib/*.ex"}},
      {"intent": {"type": "read_file", "path": "lib/signup.ex"}}
    ]})

    @proposal ~s({"justification": "done looking", "intents": [{"type": "report", "summary": "ok"}]})

    setup do
      project =
        Path.join(Current.TestTmp.dir(), "current_llm_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "lib/signup.ex"), "defmodule Signup do\nend\n")
      File.write!(Path.join(project, ".env"), "TOKEN=#{@secret}\n")
      File.write!(Path.join(Path.dirname(project), "outside.txt"), @secret)

      on_exit(fn ->
        File.rm_rf!(project)
        File.rm(Path.join(Path.dirname(project), "outside.txt"))
      end)

      %{project: project}
    end

    # The fake model answers each call with the next reply in `replies`
    # (repeating the last one), and every prompt it is given is sent to
    # the test as {:prompt, n, prompt}.
    defp script(replies) do
      test_pid = self()
      calls = :counters.new(1, [])

      FakeLLMClient.set_response(fn prompt ->
        :counters.add(calls, 1, 1)
        n = :counters.get(calls, 1)
        send(test_pid, {:prompt, n, prompt})
        {:ok, Enum.at(replies, n - 1, List.last(replies))}
      end)
    end

    defp prompt!(n) do
      assert_receive {:prompt, ^n, prompt}, 5_000
      prompt
    end

    test "is given the layout, then what it asked for, and its proposal ends the workflow",
         %{project: project} do
      script([@observe_signup, @proposal])

      task_id = submit!([mode: :plan], project)
      workflow_id = await_workflow_created(task_id)

      first = prompt!(1)
      assert first =~ "lib/signup.ex (24 bytes)"
      refute first =~ "defmodule Signup"
      refute first =~ ".env"

      second = prompt!(2)
      assert second =~ "glob lib/*.ex in .\n1 match\nlib/signup.ex"
      assert second =~ ~s(<file path="lib/signup.ex">\ndefmodule Signup do\nend\n</file>)

      # One proposal, however many turns it took.
      %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)
      assert [%Current.Intent.Report{summary: "ok"}] = proposal.intents

      await(:workflow_completed, workflow_id)
      assert {:ok, :planned} = Current.get_status(task_id)
      refute_received {:prompt, 3, _}
    end

    test "is told, before anything else, that it replies with one of two shapes",
         %{project: project} do
      script([@proposal])

      submit!([mode: :plan], project) |> await_workflow_created()
      prompt = prompt!(1)

      # The protocol comes first: both replies, and which is for what.
      assert prompt =~ "exactly ONE JSON object"
      assert prompt =~ "CONTEXT REQUEST"
      assert prompt =~ "PROPOSAL"
      assert prompt =~ "Do not put read_file, glob or grep in a"

      # The schema it is given starts with that choice too.
      assert prompt =~ ~s("oneOf")
      assert prompt =~ "definitions.context_request"
    end

    test "its proposal carries what it looked at and why, leading to what it was shown",
         %{project: project} do
      script([@observe_signup, @proposal])

      workflow_id = submit!([mode: :plan], project) |> await_workflow_created()

      %Event.ProposalProduced{proposal: proposal} =
        produced = await(:proposal_produced, workflow_id)

      assert [%Observation{} = glob, %Observation{} = read] = proposal.observations

      # What it asked for and why, in which reply...
      assert %{round: 1, status: :shown, reason: "find the modules"} = glob
      assert %Intent.Glob{pattern: "lib/*.ex"} = glob.intent

      assert %{round: 1, status: :shown, reason: nil} = read
      assert %Intent.ReadFile{path: "lib/signup.ex"} = read.intent
      assert {:ok, @observe_signup} = Current.BlobStore.read(read.reply_artifact_id)

      # ...and where to find what it was shown.
      assert {:ok, "1 match\nlib/signup.ex"} = Current.BlobStore.read(glob.artifact_id)
      assert {:ok, "defmodule Signup do\nend\n"} = Current.BlobStore.read(read.artifact_id)

      # Ids only: no contents in the proposal or the event.
      refute inspect(produced) =~ "defmodule Signup"

      # They belong to the proposal now, and their intents say so.
      assert Enum.all?(proposal.observations, &(&1.intent.proposal_id == proposal.id))

      # The stored proposal carries them too, and `current proposal` shows them.
      await(:workflow_completed, workflow_id)
      assert {:ok, view} = Current.RPC.proposal(proposal.id)
      assert view.proposal.observations == proposal.observations

      assert Current.CLI.Render.proposal(view) =~
               "Observed before proposing\n  1. glob lib/*.ex in .\n" <>
                 "       why      find the modules\n       shown    sha256:"
    end

    test "a refused request is on record too, with the reason", %{project: project} do
      script([
        ~s({"observe": [{"intent": {"type": "read_file", "path": ".env"}}]}),
        ~s({"observe": [{"intent": {"type": "read_file", "path": "lib/signup.ex"}}]}),
        @proposal
      ])

      workflow_id = submit!([mode: :plan], project) |> await_workflow_created()
      %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)

      assert [refused, read] = proposal.observations

      assert %Observation{round: 1, status: :refused, artifact_id: nil, error: error} = refused
      assert %Intent.ReadFile{path: ".env"} = refused.intent
      assert error =~ ".env is excluded"

      assert %Observation{round: 2, status: :shown} = read
      assert %Intent.ReadFile{path: "lib/signup.ex"} = read.intent
    end

    test "a proposal on the first reply has no observations", %{project: project} do
      script([@proposal])

      workflow_id = submit!([mode: :plan], project) |> await_workflow_created()
      %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)

      assert proposal.observations == []
    end

    test "is told no, not shown, when it asks for secrets or for files outside the project",
         %{project: project} do
      script([
        ~s({"observe": [
          {"intent": {"type": "read_file", "path": ".env"}},
          {"intent": {"type": "read_file", "path": "../outside.txt"}},
          {"intent": {"type": "grep", "pattern": "TOKEN", "paths": [".env"]}},
          {"intent": {"type": "glob", "pattern": ".env*"}}
        ]}),
        @proposal
      ])

      workflow_id = submit!([mode: :plan], project) |> await_workflow_created()

      second = prompt!(2)
      assert second =~ "read_file .env\nerror: .env is not available"
      assert second =~ "read_file ../outside.txt\nerror: path is outside the project directory"
      assert second =~ "glob .env* in .\n0 matches"
      refute second =~ @secret

      # Being refused is an answer, not a failure.
      await(:workflow_completed, workflow_id)
    end

    test "fails production if it never stops asking", %{project: project} do
      script([@observe_signup])

      task_id = submit!([mode: :plan], project)
      workflow_id = await_workflow_created(task_id)

      error = production_error(workflow_id)
      assert error.stage == :context_budget
      assert error.raw_output_blob_id != nil

      # Eight requests were run; the ninth prompt demanded a proposal.
      assert prompt!(8) =~ "You may make 1 more context request"
      assert prompt!(9) =~ "You have no context requests left"
      refute_received {:prompt, 10, _}

      await(:workflow_failed, workflow_id)
      assert {:ok, :failed} = Current.get_status(task_id)
    end

    test "is cut off by the per-task timeout, and nothing arrives late",
         %{project: project} do
      put_env(:llm_task_timeout_ms, 300)

      # Answers quickly, every time, and never proposes: only the bound
      # on the whole task can stop this.
      calls = :counters.new(1, [])

      FakeLLMClient.set_response(fn _prompt ->
        :counters.add(calls, 1, 1)
        Process.sleep(100)
        {:ok, @observe_signup}
      end)

      task_id = submit!([mode: :plan], project)
      workflow_id = await_workflow_created(task_id)

      error = production_error(workflow_id)
      assert error.stage == :timeout
      assert error.reason == "no proposal after 300ms"

      await(:workflow_failed, workflow_id)
      assert {:ok, :failed} = Current.get_status(task_id)

      # The killed build takes no further step: the model isn't called
      # again, no proposal turns up, and the log has nothing after the
      # failure.
      calls_at_failure = :counters.get(calls, 1)
      events_at_failure = length(events(workflow_id))

      refute_receive {:proposal_produced, _}, 500
      assert :counters.get(calls, 1) == calls_at_failure
      assert length(events(workflow_id)) == events_at_failure
      assert {:ok, :failed} = Current.get_status(task_id)
    end
  end

  test "a failure inside the builder itself fails production once, at the internal stage" do
    # A client that breaks its contract: the reply isn't text, which the
    # builder only finds out when it tries to store it.
    {task_id, workflow_id} = submit_with_response({:ok, 123})

    error = production_error(workflow_id)
    assert error.stage == :internal
    assert error.reason =~ "FunctionClauseError"
    assert error.reason =~ " at "

    # Recorded as a failure -- not an orchestrator crash that gets retried.
    await(:workflow_failed, workflow_id)
    assert {:ok, %{status: :failed, error: message}} = Current.get_workflow(task_id)
    assert message =~ "the proposal builder failed unexpectedly"
    refute Enum.any?(events(workflow_id), &is_struct(&1, Event.WorkflowAbandoned))
  end

  test "a model that never answers fails production at the timeout stage" do
    put_env(:llm_proposal_timeout_ms, 100)

    {task_id, workflow_id} = submit_with_response(:hang)

    assert production_error(workflow_id).stage == :timeout

    await(:workflow_failed, workflow_id)
    assert {:ok, :failed} = Current.get_status(task_id)
  end
end
