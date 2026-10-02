defmodule Current.IntentPathsTest do
  use ExUnit.Case, async: true

  alias Current.{Id, Intent, IntentPaths, Proposal}

  defp proposal(intents),
    do: %Proposal{id: Id.generate(), workflow_id: Id.generate(), intents: intents}

  describe "absolutize/2" do
    test "expands every path field against project_dir and leaves other intents alone" do
      read = %Intent.ReadFile{id: Id.generate(), proposal_id: Id.generate(), path: "lib/a.ex"}

      grep = %Intent.Grep{
        id: Id.generate(),
        proposal_id: Id.generate(),
        pattern: "x",
        paths: ["a", "/abs/b"]
      }

      glob = %Intent.Glob{id: Id.generate(), proposal_id: Id.generate(), pattern: "*.ex"}
      cmd = %Intent.RunCommand{id: Id.generate(), proposal_id: Id.generate(), cmd: "mix"}

      %Proposal{intents: [read, grep, glob, cmd2]} =
        IntentPaths.absolutize(proposal([read, grep, glob, cmd]), "/proj")

      assert read.path == "/proj/lib/a.ex"
      assert grep.paths == ["/proj/a", "/abs/b"]
      assert glob.base_dir == "/proj"
      assert glob.pattern == "*.ex"
      assert cmd2 == cmd
    end

    test "leaves an empty path empty instead of turning it into project_dir" do
      delete = %Intent.DeleteFile{id: Id.generate(), proposal_id: Id.generate(), path: ""}
      %Proposal{intents: [delete]} = IntentPaths.absolutize(proposal([delete]), "/proj")
      assert delete.path == ""
    end
  end

  describe "within?/2" do
    test "is segment-aware" do
      assert IntentPaths.within?("/proj", "/proj")
      assert IntentPaths.within?("/proj/a/b", "/proj")
      refute IntentPaths.within?("/proj_evil/a", "/proj")
      refute IntentPaths.within?("/proj/../etc", "/proj")
      assert IntentPaths.within?("/anything", "/")
    end
  end

  describe "parent_segment?/1" do
    test "matches '..' segments only" do
      assert IntentPaths.parent_segment?("..")
      assert IntentPaths.parent_segment?("a/../b")
      assert IntentPaths.parent_segment?("/a/b/..")
      refute IntentPaths.parent_segment?("a..b")
      refute IntentPaths.parent_segment?("...")
      refute IntentPaths.parent_segment?("/a/.hidden")
    end
  end
end
