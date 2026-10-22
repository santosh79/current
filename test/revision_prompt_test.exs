defmodule Current.RevisionPromptTest do
  use ExUnit.Case, async: true

  alias Current.{Intent, LLMProposalBuilder, Proposal}

  defp proposal(id, intents, extra \\ %{}) do
    struct!(
      Proposal,
      Map.merge(
        %{
          id: id,
          workflow_id: "w",
          intents: intents,
          justification: "because #{id}",
          claims: ["it works"]
        },
        extra
      )
    )
  end

  test "nothing is added for a first proposal" do
    assert LLMProposalBuilder.render_revision(nil, "/proj") == ""
  end

  test "renders every proposal, every round of feedback and the replacement instruction" do
    p1 =
      proposal("p1", [%Intent.RunCommand{id: "i1", proposal_id: "p1", cmd: "mix", args: ["test"]}])

    p2 =
      proposal(
        "p2",
        [%Intent.ReadFile{id: "i2", proposal_id: "p2", path: "/proj/lib/a.ex"}],
        %{
          revision: 1,
          revises: "p1",
          observations: [
            %Current.Observation{
              id: "o",
              intent: %Intent.ReadFile{id: "x", proposal_id: nil, path: "lib/a.ex"},
              status: :shown
            },
            %Current.Observation{
              id: "o2",
              intent: %Intent.ReadFile{id: "y", proposal_id: nil, path: ".env"},
              status: :refused
            }
          ]
        }
      )

    text =
      LLMProposalBuilder.render_revision(
        %{previous: [p1, p2], feedback: ["use mix compile", "keep it smaller"]},
        "/proj"
      )

    assert text =~ "Proposal 1:"
    assert text =~ "Proposal 2 (the latest):"
    assert text =~ "because p1"
    assert text =~ "run_command mix test"
    # paths are shown relative to the project
    assert text =~ "read_file lib/a.ex"
    refute text =~ "/proj/lib/a.ex"
    # feedback keeps its order and is attributed to its proposal
    assert text =~ ~s(Feedback on proposal 1: "use mix compile")
    assert text =~ ~s(Feedback on proposal 2: "keep it smaller")
    # shown observations are hints; refused ones are not
    assert text =~ "What you looked at before"
    refute text =~ ".env"
    assert text =~ "complete replacement proposal"
  end

  test "no observation hints when nothing was looked at" do
    p1 = proposal("p1", [])
    text = LLMProposalBuilder.render_revision(%{previous: [p1], feedback: ["x"]}, "/proj")
    refute text =~ "What you looked at before"
    assert text =~ "Proposal 1 (the latest):"
  end
end
