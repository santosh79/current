defmodule Current.CLI.RenderTest do
  @moduledoc """
  How `current events` words a claim and the evidence it was checked
  against. Pure rendering: events are built by hand, no runtime.
  """

  use ExUnit.Case, async: true

  alias Current.{EffectResult, Event, Intent}
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

  test "a grep claim shows the observed match count against the condition" do
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
