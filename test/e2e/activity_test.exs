defmodule Current.E2E.ActivityTest do
  @moduledoc """
  What a model asks to see while it works reaches a client polling
  Current.RPC.activity/3: builder -> hub -> RPC.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{FakeLLMClient, LLMProposalBuilder}

  setup do
    use_proposal_builder(LLMProposalBuilder)

    project =
      Path.join(System.tmp_dir!(), "current_activity_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(project, "lib"))
    File.write!(Path.join(project, "lib/a.ex"), "defmodule A do\nend\n")
    on_exit(fn -> File.rm_rf!(project) end)

    %{project: project}
  end

  test "each round is visible to a poller, and a caught-up poller sees nothing new",
       %{project: project} do
    FakeLLMClient.set_response(fn prompt ->
      if prompt =~ ~s(<file path="lib/a.ex">) do
        {:ok, ~s({"justification": "done", "intents": [{"type": "report", "summary": "ok"}]})}
      else
        {:ok, ~s({"observe": [{"intent": {"type": "read_file", "path": "lib/a.ex"}}]})}
      end
    end)

    workflow_id = submit!([mode: :plan], project) |> await_workflow_created()
    await(:workflow_completed, workflow_id)

    assert %{
             epoch: epoch,
             last_seq: 2,
             items: [
               %{type: :requested, round: 1, entries: [%{label: "read_file lib/a.ex"}]},
               %{type: :settled, round: 1, entries: [%{status: :shown, bytes: bytes}]}
             ]
           } = Current.RPC.activity(workflow_id)

    assert bytes > 0
    assert %{items: [], last_seq: 2} = Current.RPC.activity(workflow_id, epoch, 2)
  end
end
