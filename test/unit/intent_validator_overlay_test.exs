defmodule Current.IntentValidatorOverlayTest do
  @moduledoc """
  Validation checks each intent against the files as the proposal's
  earlier intents leave them (an in-memory overlay), not against the files
  on disk. These tests cover that carry-over between intents.

  Like the other validator tests, they pass "/" as project_dir so path
  containment is trivially satisfied and only the intent rules are tested.
  """

  use ExUnit.Case, async: false

  alias Current.{BlobStore, Id, Intent, IntentValidator, Proposal}
  alias Current.Error.ValidationError

  ## Helpers

  defp proposal(intents) do
    %Proposal{id: Id.generate(), workflow_id: Id.generate(), intents: intents}
  end

  defp unique_path do
    Path.join(System.tmp_dir!(), "iv_overlay_#{System.unique_integer([:positive])}")
  end

  # A file that exists on disk with `contents`.
  defp tmp_file!(contents) do
    path = unique_path()
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A path with nothing on disk.
  defp missing_path! do
    path = unique_path()
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp edit(path, old, new, replace_all \\ false) do
    {:ok, old_id} = BlobStore.put(old)
    {:ok, new_id} = BlobStore.put(new)

    %Intent.EditFile{
      id: Id.generate(),
      proposal_id: Id.generate(),
      path: path,
      old_artifact_id: old_id,
      new_artifact_id: new_id,
      replace_all: replace_all
    }
  end

  defp write(path, contents) do
    {:ok, blob_id} = BlobStore.put(contents)

    %Intent.WriteFile{
      id: Id.generate(),
      proposal_id: Id.generate(),
      path: path,
      contents_artifact_id: blob_id
    }
  end

  defp delete(path),
    do: %Intent.DeleteFile{id: Id.generate(), proposal_id: Id.generate(), path: path}

  defp read(path),
    do: %Intent.ReadFile{id: Id.generate(), proposal_id: Id.generate(), path: path}

  defp grep(paths),
    do: %Intent.Grep{id: Id.generate(), proposal_id: Id.generate(), pattern: "x", paths: paths}

  defp run(cmd),
    do: %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: cmd}

  defp validate(intents), do: IntentValidator.validate(proposal(intents), "/")

  ## Edit after edit

  describe "edit_file after edit_file on the same path" do
    test "passes when the second edit matches text the first one introduced" do
      path = tmp_file!("hello world")

      assert :ok =
               validate([
                 edit(path, "hello", "goodbye"),
                 edit(path, "goodbye world", "farewell")
               ])
    end

    test "fails when the first edit removed the text the second one matches" do
      path = tmp_file!("hello world")

      assert {:error, %ValidationError{reason: reason}} =
               validate([
                 edit(path, "hello", "bye"),
                 edit(path, "hello", "again")
               ])

      assert reason =~ "not found in the file"
    end

    test "fails when the first edit made the second one's old_string ambiguous" do
      # "foo" is unique in the file on disk, but not once "bar" becomes "foo".
      path = tmp_file!("foo bar")

      assert {:error, %ValidationError{reason: reason}} =
               validate([
                 edit(path, "bar", "foo"),
                 edit(path, "foo", "baz")
               ])

      assert reason =~ "matches 2 places"
    end

    test "passes when the ambiguity the first edit created is covered by replace_all" do
      path = tmp_file!("foo bar")

      assert :ok =
               validate([
                 edit(path, "bar", "foo"),
                 edit(path, "foo", "baz", true)
               ])
    end

    test "edits to different files do not affect each other" do
      a = tmp_file!("alpha")
      b = tmp_file!("beta")

      assert :ok = validate([edit(a, "alpha", "one"), edit(b, "beta", "two")])

      assert {:error, %ValidationError{reason: reason}} =
               validate([edit(a, "alpha", "one"), edit(b, "alpha", "two")])

      assert reason =~ "not found in the file"
    end
  end

  ## Edit after write

  describe "edit_file after write_file" do
    test "passes for a file that exists nowhere but in the proposal" do
      path = missing_path!()

      assert :ok =
               validate([
                 write(path, "defmodule A do\nend\n"),
                 edit(path, "defmodule A do\n", "defmodule A do\n  @moduledoc false\n")
               ])
    end

    test "fails when old_string is not in what the write_file will create" do
      path = missing_path!()

      assert {:error, %ValidationError{reason: reason}} =
               validate([write(path, "one"), edit(path, "two", "three")])

      assert reason =~ "not found in the file"
    end

    test "the edit sees the rewritten contents, not what was on disk before" do
      path = tmp_file!("on disk")

      # The file is deleted first so that the write_file is a legitimate
      # rewrite. From then on the overlay holds "rewritten".
      assert :ok =
               validate([
                 delete(path),
                 write(path, "rewritten"),
                 edit(path, "rewritten", "edited")
               ])

      assert {:error, %ValidationError{reason: reason}} =
               validate([
                 delete(path),
                 write(path, "rewritten"),
                 edit(path, "on disk", "edited")
               ])

      assert reason =~ "not found in the file"
    end
  end

  ## Edit / read / grep after delete

  describe "intents after delete_file" do
    test "edit_file fails: the file is gone" do
      path = tmp_file!("hello")

      assert {:error, %ValidationError{reason: reason}} =
               validate([delete(path), edit(path, "hello", "bye")])

      assert reason =~ "path does not exist"
    end

    test "read_file fails: the file is gone" do
      path = tmp_file!("hello")

      assert {:error, %ValidationError{reason: reason}} = validate([delete(path), read(path)])
      assert reason =~ "read_file path does not exist"
    end

    test "grep fails when any listed path was deleted" do
      kept = tmp_file!("x")
      gone = tmp_file!("x")

      assert {:error, %ValidationError{reason: reason, details: %{path: path}}} =
               validate([delete(gone), grep([kept, gone])])

      assert reason =~ "grep path does not exist"
      assert path == gone
    end

    test "deleting a file the proposal never touched leaves other files alone" do
      kept = tmp_file!("hello")
      gone = tmp_file!("bye")

      assert :ok = validate([delete(gone), edit(kept, "hello", "hi"), read(kept)])
    end
  end

  ## Read / grep after write

  describe "read_file and grep after write_file" do
    test "read_file passes for a file the proposal creates" do
      path = missing_path!()
      assert :ok = validate([write(path, "new"), read(path)])
    end

    test "grep passes for files the proposal creates" do
      created = missing_path!()
      existing = tmp_file!("x")
      assert :ok = validate([write(created, "x"), grep([created, existing])])
    end

    test "read_file still fails for a missing file nothing creates" do
      assert {:error, %ValidationError{reason: reason}} = validate([read(missing_path!())])
      assert reason =~ "read_file path does not exist"
    end

    test "read_file fails if the write_file comes after it" do
      path = missing_path!()

      assert {:error, %ValidationError{reason: reason}} =
               validate([read(path), write(path, "new")])

      assert reason =~ "read_file path does not exist"
    end
  end

  ## write_file against earlier intents

  describe "write_file after an earlier intent on the same path" do
    test "passes after delete_file, even though the file exists on disk" do
      path = tmp_file!("old")
      assert :ok = validate([delete(path), write(path, "new")])
    end

    test "fails after an earlier write_file to the same path" do
      path = missing_path!()

      assert {:error, %ValidationError{reason: reason}} =
               validate([write(path, "one"), write(path, "two")])

      assert reason =~ "already exists earlier in this proposal"
    end

    test "fails after an edit_file of the same path" do
      path = tmp_file!("hello")

      assert {:error, %ValidationError{reason: reason}} =
               validate([edit(path, "hello", "bye"), write(path, "again")])

      assert reason =~ "already exists earlier in this proposal"
    end

    test "still does not check the disk for a path the proposal has not touched" do
      existing = tmp_file!("on disk")
      assert :ok = validate([write(existing, "new")])
    end

    test "a write_file to a path that was written, deleted, then written again passes" do
      path = missing_path!()
      assert :ok = validate([write(path, "one"), delete(path), write(path, "two")])
    end
  end

  ## run_command

  describe "run_command" do
    test "does not reset what earlier file intents did" do
      path = tmp_file!("hello world")

      assert :ok =
               validate([
                 edit(path, "hello", "goodbye"),
                 run("echo"),
                 edit(path, "goodbye world", "farewell")
               ])
    end

    test "does not hide a file the proposal deleted" do
      path = tmp_file!("hello")

      assert {:error, %ValidationError{reason: reason}} =
               validate([delete(path), run("echo"), read(path)])

      assert reason =~ "read_file path does not exist"
    end
  end

  ## Validation has no side effects

  describe "side effects" do
    test "validating edits never changes the file on disk" do
      path = tmp_file!("hello world")

      assert :ok =
               validate([
                 edit(path, "hello", "goodbye"),
                 edit(path, "goodbye world", "farewell")
               ])

      assert File.read!(path) == "hello world"
    end

    test "validating a write_file never creates the file" do
      path = missing_path!()
      assert :ok = validate([write(path, "new"), edit(path, "new", "newer")])
      refute File.exists?(path)
    end

    test "validating a delete_file never removes the file" do
      path = tmp_file!("keep me")
      assert :ok = validate([delete(path)])
      assert File.read!(path) == "keep me"
    end

    test "state does not leak between validate/2 calls" do
      path = tmp_file!("hello")

      assert :ok = validate([delete(path)])
      assert :ok = validate([read(path)])
    end
  end

  ## Which intent gets blamed

  describe "error attribution" do
    test "the error names the intent whose check failed, not an earlier one" do
      path = tmp_file!("hello world")
      first = edit(path, "hello", "bye")
      second = edit(path, "hello", "again")

      assert {:error, %ValidationError{intent_id: id}} = validate([first, second])
      assert id == second.id
    end
  end
end
