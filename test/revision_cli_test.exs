defmodule Current.RevisionCLITest do
  use ExUnit.Case, async: true

  alias Current.CLI
  alias Current.CLI.{Render, ReviewMarkdown}

  describe "parse/1 revise" do
    test "id and feedback" do
      assert {:revise, "abcd", "drop the logging"} =
               CLI.parse(["revise", "abcd", "-m", "drop the logging"])

      assert {:revise, "abcd", "x"} = CLI.parse(["revise", "abcd", "--message", "x"])
    end

    test "feedback is required and non-blank" do
      assert {:error, "revise needs --message <feedback>"} = CLI.parse(["revise", "abcd"])

      assert {:error, "revise needs --message <feedback>"} =
               CLI.parse(["revise", "abcd", "-m", "  "])
    end

    test "needs exactly one id" do
      assert {:error, "revise needs a proposal id"} = CLI.parse(["revise", "-m", "x"])

      assert {:error, "revise takes exactly one proposal id"} =
               CLI.parse(["revise", "a", "b", "-m", "x"])
    end

    test "unknown flags and help" do
      assert {:error, "invalid option --nope"} = CLI.parse(["revise", "a", "--nope", "x"])
      assert :help = CLI.parse(["revise", "--help"])
    end
  end

  describe "Render" do
    defp entry(position, event), do: %{"position" => position, "event" => event}

    defp view(status, events) do
      %{
        "workflow_id" => "sha256:wf",
        "status" => status,
        "mode" => "apply",
        "terminal" => false,
        "task" => nil,
        "entries" => events |> Enum.with_index(1) |> Enum.map(fn {e, i} -> entry(i, e) end)
      }
    end

    defp proposal(id, extra \\ %{}),
      do: Map.merge(%{"id" => id, "intents" => [], "claims" => [], "justification" => nil}, extra)

    test "outcome shows the latest proposal, its revision, and the feedback it answers" do
      p1 = proposal("sha256:p1")
      p2 = proposal("sha256:p2", %{"revision" => 1, "revises" => "sha256:p1"})

      events = [
        %{"type" => "WorkflowCreated", "max_revisions" => 10},
        %{"type" => "ProposalProduced", "proposal" => p1, "raw_output_blob_id" => nil},
        %{"type" => "ProposalValidated"},
        %{
          "type" => "ProposalRevisionRequested",
          "proposal_id" => "sha256:p1",
          "feedback" => "no logging"
        },
        %{"type" => "ProposalProduced", "proposal" => p2, "raw_output_blob_id" => nil},
        %{"type" => "ProposalValidated"}
      ]

      out = Render.outcome(view("waiting_for_approval", events))

      assert out =~ "proposal sha256:p2"
      refute out =~ "proposal sha256:p1\n"
      assert out =~ "revision 1 (replaces sha256:p1)"
      assert out =~ "no logging"
      assert out =~ "1 revision requested"
      assert out =~ "current revise sha256:p2 -m <feedback>"
      assert out =~ "9 revisions left"
    end

    test "no revise hint once the revisions are used up" do
      events =
        [%{"type" => "WorkflowCreated", "max_revisions" => 1}] ++
          [
            %{
              "type" => "ProposalProduced",
              "proposal" => proposal("sha256:p1"),
              "raw_output_blob_id" => nil
            }
          ] ++
          [
            %{
              "type" => "ProposalRevisionRequested",
              "proposal_id" => "sha256:p1",
              "feedback" => "f"
            }
          ]

      out = Render.outcome(view("waiting_for_approval", events))
      assert out =~ "no revisions left"
      refute out =~ "current revise"
    end

    test "events table has a line for the new event" do
      v =
        view("revision_requested", [
          %{
            "type" => "ProposalRevisionRequested",
            "proposal_id" => "sha256:p1",
            "feedback" => "tighten it"
          }
        ])

      assert Render.events(v) =~ ~s(tighten it)
    end

    test "proposal view marks a superseded proposal" do
      v = %{
        "proposal" => proposal("sha256:p1"),
        "workflow_id" => "sha256:wf",
        "status" => "waiting_for_approval",
        "mode" => "apply",
        "current_proposal_id" => "sha256:p2"
      }

      assert Render.proposal(v) =~ "Superseded by sha256:p2"
    end
  end

  describe "ReviewMarkdown next step" do
    defp review(extra) do
      Map.merge(
        %{
          "proposal" => %{
            "id" => "sha256:p2",
            "revision" => 1,
            "revises" => "sha256:p1",
            "claims" => []
          },
          "workflow" => %{
            "id" => "sha256:wf",
            "status" => "waiting_for_approval",
            "mode" => "apply"
          },
          "project_dir" => nil,
          "validation_error" => nil,
          "intents" => [],
          "raw_output" => nil,
          "current_proposal_id" => "sha256:p2",
          "revisions_remaining" => 9,
          "feedback" => "no logging"
        },
        extra
      )
    end

    test "offers revise with the revisions left, and shows the feedback" do
      md = ReviewMarkdown.render(review(%{}))
      assert md =~ "current revise sha256:p2"
      assert md =~ "9 revisions left"
      assert md =~ "no logging"
      assert md =~ "Revision:** 1"
    end

    test "offers no decision on a superseded proposal" do
      md = ReviewMarkdown.render(review(%{"current_proposal_id" => "sha256:p3"}))
      assert md =~ "superseded"
      refute md =~ "current approve"
      refute md =~ "current revise"
    end

    test "says so when no revisions are left" do
      md = ReviewMarkdown.render(review(%{"revisions_remaining" => 0}))
      assert md =~ "No revisions left"
      refute md =~ "current revise"
    end
  end
end
