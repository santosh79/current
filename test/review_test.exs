defmodule Current.ReviewTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Current.{CLI, Excerpt, Inspector, Intent, Proposal}
  alias Current.CLI.{ReviewJSON, ReviewMarkdown}
  alias Current.Error.ValidationError

  describe "Excerpt.take/4" do
    test "a short text is shown whole" do
      {excerpt, left} = Excerpt.take("a", {:ok, "one\ntwo\n"}, 10, 100)

      assert %Excerpt{status: :ok, text: "one\ntwo", truncated: false} = excerpt
      assert excerpt.total_lines == 2
      assert excerpt.shown_lines == 2
      assert excerpt.total_bytes == 8
      assert left == 98
    end

    test "a long text is cut to max_lines, and says so" do
      text = Enum.map_join(1..10, "\n", &"line #{&1}")
      {excerpt, left} = Excerpt.take("a", {:ok, text}, 3, 100)

      assert excerpt.text == "line 1\nline 2\nline 3"
      assert excerpt.truncated
      assert {excerpt.shown_lines, excerpt.total_lines} == {3, 10}
      refute excerpt.lines_shortened
      assert left == 97
    end

    test "the overall budget caps an excerpt below max_lines, then omits the rest" do
      text = Enum.map_join(1..10, "\n", &"line #{&1}")

      {first, left} = Excerpt.take("a", {:ok, text}, 5, 7)
      assert first.shown_lines == 5
      {second, left} = Excerpt.take("b", {:ok, text}, 5, left)
      assert second.shown_lines == 2
      assert second.truncated
      assert {%Excerpt{status: :omitted, text: nil}, 0} = Excerpt.take("c", {:ok, text}, 5, left)
    end

    test "empty, binary and missing artifacts" do
      assert {%Excerpt{status: :ok, total_lines: 0, text: ""}, 10} =
               Excerpt.take("a", {:ok, ""}, 5, 10)

      assert {%Excerpt{status: :binary, total_bytes: 3, text: nil}, 10} =
               Excerpt.take("a", {:ok, <<0xFF, 0xFE, 0x00>>}, 5, 10)

      assert {%Excerpt{status: :binary}, _} = Excerpt.take("a", {:ok, "a\0b"}, 5, 10)
      assert {%Excerpt{status: :missing}, 10} = Excerpt.take("a", {:error, :not_found}, 5, 10)
    end

    test "a very long line is shortened without splitting a character" do
      line = String.duplicate("é", 3_000)
      {excerpt, _} = Excerpt.take("a", {:ok, line}, 5, 10)

      assert excerpt.truncated
      assert String.valid?(excerpt.text)
      assert String.ends_with?(excerpt.text, " …")
      assert excerpt.lines_shortened
      assert byte_size(excerpt.text) < byte_size(line)
    end
  end

  # A review as Inspector.review/2 returns it, built by hand.
  defp review(intents, overrides \\ %{}) do
    proposal = %Proposal{
      id: "sha256:" <> String.duplicate("a", 64),
      workflow_id: "sha256:" <> String.duplicate("b", 64),
      intents: intents,
      justification: "Because.",
      claims: ["it works"],
      dependencies: []
    }

    Map.merge(
      %{
        proposal: proposal,
        workflow_id: proposal.workflow_id,
        status: :waiting_for_approval,
        mode: :apply,
        project_dir: "/proj",
        raw_output_blob_id: nil,
        validation_error: nil,
        artifacts: %{},
        raw_output: nil,
        limits: %{max_lines: 200, max_total_lines: 2000}
      },
      overrides
    )
  end

  defp excerpt(id, text, opts \\ []) do
    lines = String.split(text, "\n")

    %Excerpt{
      id: id,
      status: :ok,
      text: text,
      total_bytes: byte_size(text),
      total_lines: Keyword.get(opts, :total_lines, length(lines)),
      shown_lines: length(lines),
      truncated: Keyword.get(opts, :truncated, false)
    }
  end

  describe "ReviewMarkdown.render/1" do
    test "a FilePatch shows its diff inline, and a waiting proposal says how to approve it" do
      patch = %Intent.FilePatch{
        id: "i1",
        proposal_id: "p",
        path: "/proj/lib/a.ex",
        diff_artifact_id: "d"
      }

      diff = "--- a/lib/a.ex\n+++ b/lib/a.ex\n-old\n+new"

      md = ReviewMarkdown.render(review([patch], %{artifacts: %{"d" => excerpt("d", diff)}}))

      assert md =~ "# Proposal review"
      assert md =~ "- **Status:** waiting_for_approval (apply mode)"
      assert md =~ "## Justification\n\nBecause."
      assert md =~ "### 1. FilePatch `lib/a.ex`\n\n```diff\n#{diff}\n```"
      assert md =~ "Approve with: `current approve sha256:aaaaaaaaaaaa -m \"<message>\"`"
      assert md =~ "Approving doesn't apply it; `current apply` does that afterwards."
    end

    test "content containing a fence gets a longer fence" do
      write = %Intent.WriteFile{
        id: "i1",
        proposal_id: "p",
        path: "/proj/README.md",
        contents_artifact_id: "c"
      }

      text = "Example:\n```sh\nmix test\n```"

      md = ReviewMarkdown.render(review([write], %{artifacts: %{"c" => excerpt("c", text)}}))
      assert md =~ "````markdown\n#{text}\n````"
    end

    test "cut, binary, missing and omitted artifacts each say so and how to see them" do
      intents =
        for id <- ~w(t b m o) do
          %Intent.WriteFile{
            id: "i" <> id,
            proposal_id: "p",
            path: "/proj/#{id}.txt",
            contents_artifact_id: id
          }
        end

      artifacts = %{
        "t" => excerpt("t", "1\n2", total_lines: 50, truncated: true),
        "b" => %Excerpt{id: "b", status: :binary, total_bytes: 9},
        "o" => %Excerpt{id: "o", status: :omitted}
      }

      md = ReviewMarkdown.render(review(intents, %{artifacts: artifacts}))

      assert md =~ "_… showing 2 of 50 lines"
      assert md =~ "full: `current artifact t`_"
      assert md =~ "_Binary content (9 bytes) · `current artifact b`_"
      assert md =~ "_Artifact not found: `m`_"
      assert md =~ "_Not shown: this review's line limit was reached · `current artifact o`_"
    end

    test "a claim shows its statement and evidence in words" do
      cmd = %Intent.RunCommand{id: "c1", proposal_id: "p", cmd: "npm", args: ["test"]}

      claim = %Intent.Claim{
        id: "c2",
        proposal_id: "p",
        statement: "tests pass",
        evidence: %{source_intent_id: "c1", condition: :exit_code_equals, value: 0}
      }

      md = ReviewMarkdown.render(review([cmd, claim]))

      assert md =~ "### 1. RunCommand\n\n```sh\nnpm test\n```"

      assert md =~
               "### 2. Claim\n\n> tests pass\n\n**Evidence:** the exit code of intent 1 equals 0"
    end

    test "a validation failure is shown, and a finished proposal has no approve line" do
      read = %Intent.ReadFile{id: "r1", proposal_id: "p", path: "/etc/passwd"}
      error = %ValidationError{intent_id: "r1", reason: "path outside project"}

      md =
        ReviewMarkdown.render(
          review([read], %{status: :validation_failed, validation_error: error})
        )

      assert md =~ "## ✗ Validation failed\n\n- **At:** intent 1 (ReadFile `/etc/passwd`)"
      assert md =~ "- **Reason:** path outside project"
      refute md =~ "Approve with"
    end
  end

  describe "ReviewJSON" do
    test "a versioned document with full ids, 1-based indexes and explicit artifacts" do
      cmd = %Intent.RunCommand{id: "c1", proposal_id: "p", cmd: "npm", args: ["test"]}

      patch = %Intent.FilePatch{
        id: "i1",
        proposal_id: "p",
        path: "/proj/lib/a.ex",
        diff_artifact_id: "d"
      }

      claim = %Intent.Claim{
        id: "c2",
        proposal_id: "p",
        statement: "tests pass",
        evidence: %{source_intent_id: "c1", condition: :exit_code_equals, value: 0}
      }

      error = %ValidationError{intent_id: "c2", reason: "bad", details: %{got: {:tuple, 1}}}

      doc =
        review([cmd, patch, claim], %{
          artifacts: %{"d" => excerpt("d", "+x", truncated: true, total_lines: 9)},
          validation_error: error
        })
        |> ReviewJSON.encode()
        |> JSON.decode!()

      assert doc["schema"] == "current.review/v1"

      assert doc["workflow"] == %{
               "id" => "sha256:" <> String.duplicate("b", 64),
               "status" => "waiting_for_approval",
               "mode" => "apply"
             }

      assert doc["raw_output"] == nil

      [c, p, cl] = doc["intents"]

      assert c == %{
               "index" => 1,
               "id" => "c1",
               "type" => "RunCommand",
               "cmd" => "npm",
               "args" => ["test"]
             }

      assert p["relative_path"] == "lib/a.ex"
      assert p["artifact"]["status"] == "ok"
      assert p["artifact"]["truncated"] == true
      assert {p["artifact"]["shown_lines"], p["artifact"]["total_lines"]} == {1, 9}

      assert cl["evidence"] == %{
               "source_intent_id" => "c1",
               "source_intent_index" => 1,
               "condition" => "exit_code_equals",
               "value" => 0
             }

      assert doc["validation_error"]["intent_index"] == 3
      assert doc["validation_error"]["details"] == %{"got" => "{:tuple, 1}"}
    end
  end

  describe "current review (end to end)" do
    defp plan_proposal_id! do
      out =
        capture_io(fn ->
          assert CLI.run(["plan", "add email validation", "--dir", System.tmp_dir!()]) == 0
        end)

      [_, id] = Regex.run(~r/current proposal (sha256:[0-9a-f]+)/, out)
      id
    end

    test "parses its options" do
      assert {:review, "ab12", %{format: :markdown, max_lines: 200, raw: false}} =
               CLI.parse(["review", "ab12"])

      assert {:review, "ab12", %{format: :json, max_lines: 5, raw: true}} =
               CLI.parse(["review", "--json", "--max-lines", "5", "--raw", "ab12"])

      assert {:error, _} = CLI.parse(["review"])
      assert {:error, _} = CLI.parse(["review", "a", "b"])
      assert {:error, _} = CLI.parse(["review", "ab12", "--max-lines", "0"])
      assert {:error, _} = CLI.parse(["review", "ab12", "--nope"])
    end

    test "shows a proposal's diff as Markdown" do
      id = plan_proposal_id!()
      md = capture_io(fn -> assert CLI.run(["review", id]) == 0 end)

      assert md =~ "# Proposal review"
      assert md =~ "- **Status:** planned (plan mode)"
      assert md =~ ~r/### 1\. FilePatch `[^`]*signup\.ex`\n\n```diff\n/
      assert md =~ "+  def validate_email(email)"
      refute md =~ "Approve with"
    end

    test "--json is the same review, machine-readable" do
      id = plan_proposal_id!()
      doc = capture_io(fn -> assert CLI.run(["review", id, "--json"]) == 0 end) |> JSON.decode!()

      assert doc["schema"] == "current.review/v1"
      assert String.starts_with?(doc["proposal"]["id"], id)
      assert [%{"type" => "FilePatch", "artifact" => artifact}] = doc["intents"]
      assert artifact["text"] =~ "+  def validate_email(email)"
      assert artifact["truncated"] == false
    end

    test "--max-lines cuts each artifact" do
      id = plan_proposal_id!()

      md = capture_io(fn -> assert CLI.run(["review", id, "--max-lines", "2"]) == 0 end)
      assert md =~ "_… showing 2 of 6 lines · full: `current artifact sha256:"

      {:ok, review} = Inspector.review(id, %{max_lines: 2})
      assert review.limits == %{max_lines: 2, max_total_lines: 20}
      assert review.raw_output == nil
    end

    test "--raw adds the model's raw output, which is left out by default" do
      previous = Application.fetch_env!(:current, :proposal_builder)
      Application.put_env(:current, :proposal_builder, Current.RawOutputProposalBuilder)
      on_exit(fn -> Application.put_env(:current, :proposal_builder, previous) end)

      id = plan_proposal_id!()
      raw = Current.RawOutputProposalBuilder.raw()

      without = capture_io(fn -> assert CLI.run(["review", id]) == 0 end)
      refute without =~ "## Raw model output"

      with_raw = capture_io(fn -> assert CLI.run(["review", id, "--raw"]) == 0 end)
      assert with_raw =~ "## Raw model output\n\n```\n#{raw}\n```"

      doc = capture_io(fn -> CLI.run(["review", id, "--raw", "--json"]) end) |> JSON.decode!()
      assert doc["raw_output"]["text"] == raw
    end

    test "unknown ids" do
      err =
        capture_io(:stderr, fn ->
          assert CLI.run(["review", "sha256:ffffffffffff0000"]) == 1
        end)

      assert err =~ "no proposal matches"
    end

    test "an approved proposal says how to apply it" do
      md = ReviewMarkdown.render(review([], %{status: :approved}))

      assert md =~ "Approved. Nothing has been applied yet."
      assert md =~ "Apply with: `current apply sha256:aaaaaaaaaaaa`"
      refute md =~ "Approve with"
    end

    test "run's output points at review before approve" do
      out =
        capture_io(fn ->
          assert CLI.run(["run", "x", "--dir", System.tmp_dir!()]) == 0
        end)

      assert out =~ ~r/current review sha256:[0-9a-f]{12}\n  current approve sha256:/
    end
  end
end
