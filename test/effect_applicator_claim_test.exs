defmodule Current.EffectApplicatorTest.ClaimTest do
  use ExUnit.Case, async: false

  alias Current.{EffectApplicator, Id, Intent}

  describe "apply/2 - claim (stage 0: expected boolean)" do
    test "when no evidence is supplied it returns error" do
      intent_missing_evidence = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "signup validates email",
        expected: true,
        evidence: nil
      }

      prior_results = []

      assert {:error, "claim requires evidence"} =
               EffectApplicator.apply(intent_missing_evidence, prior_results)
    end
  end

  describe "apply/2 - claim (stage 1: evidence against prior results)" do
    test "verifies grep match count greater than 0 when matches exist" do
      grep_intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "validate_email",
        paths: []
      }

      grep_result = %Current.EffectResult.Grep{
        matches_artifact_id: "sha256:placeholder",
        match_count: 1,
        searched_artifact_ids: []
      }

      prior_results = [{grep_intent, grep_result}]

      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "validate_email exists in codebase",
        evidence: %{
          source_intent_id: grep_intent.id,
          condition: :match_count_greater_than,
          value: 0
        },
        expected: nil
      }

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)

      assert %Current.EffectResult.Claim{} = result
      assert result.verified == true
      assert result.statement == "validate_email exists in codebase"
      assert result.reason =~ "1 match"
      assert result.reason =~ "more than 0"

      assert result.evidence.source_intent_id == grep_intent.id
      assert result.evidence.condition == :match_count_greater_than
      assert result.evidence.value == 0
    end

    test "verifies grep match count fails when no matches" do
      grep_intent = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "validate_email",
        paths: []
      }

      grep_result = %Current.EffectResult.Grep{
        matches_artifact_id: "sha256:placeholder",
        match_count: 0,
        searched_artifact_ids: []
      }

      prior_results = [{grep_intent, grep_result}]

      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "validate_email exists in codebase",
        evidence: %{
          source_intent_id: grep_intent.id,
          condition: :match_count_greater_than,
          value: 0
        },
        expected: nil
      }

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == false
      assert result.reason =~ "0 match"
    end

    test "verifies command exit code equals 0" do
      cmd_intent = %Intent.RunCommand{
        id: Id.generate(),
        proposal_id: Id.generate(),
        cmd: "mix",
        args: ["test"]
      }

      cmd_result = %Current.EffectResult.Command{
        exit_code: 0,
        stdout_artifact_id: "sha256:aaa",
        stderr_artifact_id: "sha256:bbb",
        stdout_bytes: 10,
        stderr_bytes: 0
      }

      prior_results = [{cmd_intent, cmd_result}]

      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "tests pass",
        evidence: %{
          source_intent_id: cmd_intent.id,
          condition: :exit_code_equals,
          value: 0
        },
        expected: nil
      }

      assert {:ok, result} = EffectApplicator.apply(intent, prior_results)
      assert result.verified == true
      assert result.reason =~ "exited with 0"
    end

    test "returns error when referenced source intent has no prior result" do
      missing_intent_id = Id.generate()

      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "grep found something",
        evidence: %{
          source_intent_id: missing_intent_id,
          condition: :match_count_greater_than,
          value: 0
        },
        expected: nil
      }

      assert {:error, reason} = EffectApplicator.apply(intent, [])

      assert reason =~ missing_intent_id
      assert reason =~ "no such intent result found"
    end

    test "returns error for unsupported condition on result type" do
      glob_intent = %Intent.Glob{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "*.ex",
        base_dir: "."
      }

      glob_result = %Current.EffectResult.Glob{
        matches_artifact_id: "sha256:placeholder",
        match_count: 1
      }

      prior_results = [{glob_intent, glob_result}]

      intent = %Intent.Claim{
        id: Id.generate(),
        proposal_id: Id.generate(),
        statement: "something",
        evidence: %{
          source_intent_id: glob_intent.id,
          condition: :exit_code_equals,
          value: 0
        },
        expected: nil
      }

      assert {:error, reason} = EffectApplicator.apply(intent, prior_results)
      assert reason =~ "not supported"
    end
  end
end
