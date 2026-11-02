defmodule Current.ProposalFilesTest do
  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{Proposal, ProposalFiles, TaskStore, Workflow, WorkflowStore}

  describe "deterministic names" do
    test "slug normalizes text, bounds length, and cannot traverse paths" do
      assert ProposalFiles.slug("Add input validation to signup") ==
               "add-input-validation-to-signup"

      assert ProposalFiles.slug("this is a very long prompt that stops at a word boundary safely") ==
               "this-is-a-very-long-prompt-that-stops-at"

      assert String.length(
               ProposalFiles.slug(
                 "this is a very long prompt that stops at a word boundary safely"
               )
             ) <= 40

      assert ProposalFiles.slug("Café") == "cafe"
      assert ProposalFiles.slug("../../etc/passwd") == "etc-passwd"
      assert ProposalFiles.slug("") == "task"
      assert ProposalFiles.slug("東京") == "task"
      assert ProposalFiles.slug(%{prompt: "hello"}) == "task"
      assert ProposalFiles.slug(nil) == "task"
      assert ProposalFiles.slug("../../etc/passwd") =~ ~r/^[a-z0-9-]+$/
    end

    test "directory names sort by their recorded creation time" do
      id = "sha256:" <> String.duplicate("a", 64)

      early = %Workflow{
        id: id,
        task_id: id,
        status: :created,
        created_at: ~U[2026-10-29 17:08:12Z]
      }

      late = %{early | created_at: ~U[2026-10-30 01:02:03Z]}

      assert ProposalFiles.directory_name(early, "Add validation") <
               ProposalFiles.directory_name(late, "Add validation")

      assert ProposalFiles.directory_name(early, "Add validation") ==
               "20261029T170812Z-add-validation-aaaaaaaa"
    end

    test "file names contain the revision and short proposal id" do
      proposal = %Proposal{
        id: "sha256:9c03e7d1" <> String.duplicate("a", 56),
        workflow_id: "workflow",
        intents: [],
        revision: 1
      }

      assert ProposalFiles.file_name(proposal) == "r1-9c03e7d1.md"
    end
  end

  test "a deleted snapshot tree is rebuilt byte-identically" do
    root =
      Path.join(
        Current.TestTmp.dir(),
        "proposal_files_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    {task_id, workflow_id, proposal} =
      submit_and_await_valid_proposal(input: "Rebuild Café proposal files")

    assert {:ok, workflow} = WorkflowStore.get(workflow_id)
    assert {:ok, task} = TaskStore.get(task_id)

    path =
      Path.join([
        root,
        ProposalFiles.directory_name(workflow, task.input),
        ProposalFiles.file_name(proposal)
      ])

    {:ok, first_writer} =
      ProposalFiles.start_link(name: nil, dir: root, interval_ms: 10, batch_size: 2)

    first = await_file(path)
    GenServer.stop(first_writer)

    assert first =~ "# Proposal review"
    assert first =~ "- **Mode:** apply"
    refute first =~ "- **Status:**"
    refute first =~ "Approve with:"
    refute first =~ "Superseded by:"

    File.rm_rf!(root)

    {:ok, second_writer} =
      ProposalFiles.start_link(name: nil, dir: root, interval_ms: 10, batch_size: 2)

    second = await_file(path)
    GenServer.stop(second_writer)

    assert second == first
  end

  defp await_file(path, attempts \\ 500)

  defp await_file(path, 0), do: flunk("proposal file was not written: #{path}")

  defp await_file(path, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, _reason} ->
        Process.sleep(10)
        await_file(path, attempts - 1)
    end
  end
end
