defmodule Current.EffectApplicatorTest.ClaimTest do
  use ExUnit.Case, async: false

  alias Current.{EffectApplicator, Id, Intent}

  defp intent_fixture(type, payload) do
    %Intent{
      id: Id.generate(),
      proposal_id: Id.generate(),
      type: type,
      payload: payload
    }
  end

  describe "apply/1 - claim (stage 0: expected boolean)" do
    test "returns verified true when expected is true" do
      intent = intent_fixture(:claim, %{statement: "signup validates email", expected: true})
      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.verified == true
      assert result.statement == "signup validates email"
      assert result.reason == "asserted directly"
    end

    test "returns verified false when expected is false" do
      intent = intent_fixture(:claim, %{statement: "signup validates email", expected: false})
      assert {:ok, result} = EffectApplicator.apply(intent)
      assert result.verified == false
    end

    test "returns error when neither evidence nor expected is present" do
      intent = intent_fixture(:claim, %{statement: "signup validates email"})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "evidence"
      assert reason =~ "expected"
    end

    test "returns error when expected is not boolean" do
      intent = intent_fixture(:claim, %{statement: "signup validates email", expected: "true"})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "boolean"
    end
  end

  describe "apply/2 - claim (stage 1: evidence against prior results)" do
    test "verifies grep match count greater than 0 when matches exist" do
      grep_intent = intent_fixture(:grep, %{pattern: "validate_email", paths: []})

      grep_result = %Current.EffectResult.Grep{
        matches: [
          %Current.EffectResult.Grep.Match{path: "signup.ex", line: 2, text: "def validate_email"}
        ]
      }

      prior_results = [{grep_intent, grep_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "validate_email exists in codebase",
          evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: 0}
        })

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == true
      assert result.statement == "validate_email exists in codebase"
      assert result.reason =~ "1 match"
      assert result.reason =~ "more than 0"
    end

    test "verifies grep match count fails when no matches" do
      grep_intent = intent_fixture(:grep, %{pattern: "validate_email", paths: []})
      grep_result = %Current.EffectResult.Grep{matches: []}
      prior_results = [{grep_intent, grep_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "validate_email exists in codebase",
          evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: 0}
        })

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == false
      assert result.reason =~ "0 match"
    end

    test "verifies command exit code equals 0" do
      cmd_intent = intent_fixture(:run_command, %{cmd: "mix", args: ["test"]})

      cmd_result = %Current.EffectResult.Command{
        exit_code: 0,
        stdout_artifact_id: "sha256:aaa",
        stderr_artifact_id: "sha256:bbb",
        stdout_bytes: 10,
        stderr_bytes: 0
      }

      prior_results = [{cmd_intent, cmd_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "tests pass",
          evidence: %{intent_type: :run_command, condition: :exit_code_equals, value: 0}
        })

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == true
      assert result.reason =~ "exited with 0"
    end

    test "returns error when referenced intent type has no prior result" do
      intent =
        intent_fixture(:claim, %{
          statement: "grep found something",
          evidence: %{intent_type: :grep, condition: :match_count_greater_than, value: 0}
        })

      assert {:error, reason} = EffectApplicator.apply(intent, [])
      assert reason =~ "grep"
      # assert reason =~ "not found"
      assert reason =~ "no such intent result found"
    end

    test "returns error for unsupported condition on result type" do
      glob_intent = intent_fixture(:glob, %{pattern: "*.ex", base_dir: "."})
      glob_result = %Current.EffectResult.Glob{matches: ["lib/app.ex"]}
      prior_results = [{glob_intent, glob_result}]

      intent =
        intent_fixture(:claim, %{
          statement: "something",
          evidence: %{intent_type: :glob, condition: :exit_code_equals, value: 0}
        })

      assert {:error, reason} = EffectApplicator.apply(intent, prior_results)
      assert reason =~ "not supported"
    end
  end
end
