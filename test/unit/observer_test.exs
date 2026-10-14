defmodule Current.ObserverTest do
  @moduledoc """
  What a model can and cannot get to see by asking. The intents here are
  as a model would write them: relative paths, chosen by something that
  must be assumed to ask for anything.
  """

  use ExUnit.Case, async: true

  alias Current.{Id, Intent, Observation, Observer}

  @secret "hunter2"
  @budget 100_000

  setup do
    base =
      Path.join(Current.TestTmp.dir(), "observer_#{System.unique_integer([:positive])}")

    project = Path.join(base, "project")
    outside = Path.join(base, "outside")

    files = %{
      "lib/a.ex" => "defmodule A do\n  def hello, do: :world\nend\n",
      "lib/b.ex" => "defmodule B do\n  def hello, do: A.hello()\nend\n",
      "node_modules/pkg/index.js" => "module.exports = '#{@secret}'\n",
      ".env" => "TOKEN=#{@secret}\n"
    }

    for {path, contents} <- files do
      File.mkdir_p!(Path.join(project, Path.dirname(path)))
      File.write!(Path.join(project, path), contents)
    end

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "credentials"), "AWS_SECRET=#{@secret}\n")
    on_exit(fn -> File.rm_rf!(base) end)

    %{project: project, outside: outside}
  end

  defp observation(intent), do: %Observation{id: Id.generate(), intent: intent}

  defp read(path),
    do: observation(%Intent.ReadFile{id: Id.generate(), proposal_id: nil, path: path})

  defp glob(pattern, base_dir \\ "."),
    do:
      observation(%Intent.Glob{
        id: Id.generate(),
        proposal_id: nil,
        pattern: pattern,
        base_dir: base_dir
      })

  defp grep(pattern, paths),
    do:
      observation(%Intent.Grep{
        id: Id.generate(),
        proposal_id: nil,
        pattern: pattern,
        paths: paths
      })

  # The text the model is given for the one observation asked for.
  defp observe!(observation, project, budget \\ @budget) do
    {[{%Observation{id: id}, text}], _budget} = Observer.observe([observation], project, budget)
    assert id == observation.id
    text
  end

  describe "what is shown" do
    test "read_file shows the file, by its project-relative path", %{project: project} do
      assert observe!(read("lib/a.ex"), project) == """
             read_file lib/a.ex
             <file path="lib/a.ex">
             defmodule A do
               def hello, do: :world
             end
             </file>\
             """
    end

    test "glob lists the matching paths", %{project: project} do
      assert observe!(glob("lib/*.ex"), project) == """
             glob lib/*.ex in .
             2 matches
             lib/a.ex
             lib/b.ex\
             """
    end

    test "grep lists the matching lines with path and line number", %{project: project} do
      assert observe!(grep("def hello", ["lib/a.ex", "lib/b.ex"]), project) == """
             grep "def hello" in lib/a.ex, lib/b.ex
             2 matching lines
             lib/a.ex:2:   def hello, do: :world
             lib/b.ex:2:   def hello, do: A.hello()\
             """
    end

    test "each result says where what was shown can be found again", %{project: project} do
      {[{read, _}, {glob, _}, {refused, _}], _budget} =
        Observer.observe([read("lib/a.ex"), glob("lib/*.ex"), read(".env")], project, @budget)

      # A file: its contents exactly as read.
      assert read.status == :shown
      assert {:ok, contents} = Current.BlobStore.read(read.artifact_id)
      assert contents == File.read!(Path.join(project, "lib/a.ex"))
      assert read.error == nil

      # The observation itself never holds contents.
      refute inspect(read) =~ "def hello"

      # A listing: what the model was shown, after the policy and the caps.
      assert {:ok, "2 matches\nlib/a.ex\nlib/b.ex"} = Current.BlobStore.read(glob.artifact_id)

      # Nothing shown, nothing to find -- only why.
      assert refused.status == :refused
      assert refused.artifact_id == nil
      assert refused.error =~ ".env is excluded"
    end

    test "results come back in the order asked, and are charged to the budget",
         %{project: project} do
      intents = [glob("lib/*.ex"), read("lib/b.ex")]

      assert {[{_, "glob" <> _}, {_, "read_file lib/b.ex" <> _}], left} =
               Observer.observe(intents, project, @budget)

      assert left < @budget
    end
  end

  describe "what is refused, and said so instead of failing" do
    test "a file that doesn't exist", %{project: project} do
      assert observe!(read("lib/nope.ex"), project) =~ "error: file not found"
    end

    test "a path that climbs out of the project", %{project: project} do
      text = observe!(read("../outside/credentials"), project)

      assert text =~ "error: path is outside the project directory"
      refute text =~ @secret
    end

    test "an absolute path elsewhere", %{project: project, outside: outside} do
      text = observe!(read(Path.join(outside, "credentials")), project)

      assert text =~ "error: path is outside the project directory"
      refute text =~ @secret
    end

    test "a symlink inside the project that points outside it",
         %{project: project, outside: outside} do
      File.ln_s!(Path.join(outside, "credentials"), Path.join(project, "creds.txt"))
      File.ln_s!(outside, Path.join(project, "vendor"))

      for intent <- [
            read("creds.txt"),
            read("vendor/credentials"),
            grep("AWS", ["creds.txt"]),
            glob("*", "vendor")
          ] do
        text = observe!(intent, project)

        assert text =~ "outside the project directory"
        refute text =~ @secret
      end
    end

    test "secrets and dependencies, by name", %{project: project} do
      for intent <- [
            read(".env"),
            grep("TOKEN", [".env"]),
            read("node_modules/pkg/index.js"),
            glob("**/*.js", "node_modules")
          ] do
        text = observe!(intent, project)

        assert text =~ "is excluded"
        refute text =~ @secret
      end
    end

    test "a secret behind a symlink with an innocent name", %{project: project} do
      File.ln_s!(".env", Path.join(project, "settings.txt"))

      text = observe!(read("settings.txt"), project)

      assert text =~ ".env is excluded"
      refute text =~ @secret
    end

    test "glob never lists what couldn't be read", %{project: project, outside: outside} do
      File.ln_s!(outside, Path.join(project, "vendor"))

      text = observe!(glob("**/*"), project)

      assert text =~ "lib/a.ex"
      refute text =~ "node_modules"
      refute text =~ "credentials"

      refute observe!(glob("{.env,.env*}"), project) =~ "\n.env"
    end

    test "a binary file", %{project: project} do
      File.write!(Path.join(project, "logo.png"), <<0xFF, 0xD8, 0xFF, 0x00>>)
      assert observe!(read("logo.png"), project) =~ "error: logo.png is a binary file"
    end

    test "a file too large to show", %{project: project} do
      File.write!(Path.join(project, "big.txt"), String.duplicate("x", 200_001))
      assert observe!(read("big.txt"), project) =~ "error: big.txt is 200001 bytes; the limit is"
    end

    test "anything that isn't a read", %{project: project} do
      delete =
        observation(%Intent.DeleteFile{id: Id.generate(), proposal_id: nil, path: "lib/a.ex"})

      assert observe!(delete, project) =~ "error: only read_file, glob and grep can be observed"
      assert File.exists?(Path.join(project, "lib/a.ex"))
    end
  end

  describe "limits" do
    test "the budget is charged exactly the text returned, shown or refused",
         %{project: project} do
      {made, left} =
        Observer.observe(
          [read("lib/a.ex"), glob("lib/*.ex"), read("lib/nope.ex")],
          project,
          @budget
        )

      assert [{%{status: :shown}, _}, {%{status: :shown}, _}, {%{status: :refused}, _}] = made

      shown_bytes = made |> Enum.map(fn {_observation, text} -> byte_size(text) end) |> Enum.sum()
      assert left == @budget - shown_bytes
    end

    test "a result that doesn't fit what is left is refused; only the refusal is charged",
         %{project: project} do
      File.write!(Path.join(project, "lib/long.ex"), String.duplicate("# filler\n", 200))

      assert {[{%Observation{status: :refused, artifact_id: nil}, text}], left} =
               Observer.observe([read("lib/long.ex")], project, 500)

      assert text =~ "error: not shown"
      refute text =~ "# filler"
      assert left == 500 - byte_size(text)
      assert left > 0
    end

    test "a refusal is still delivered when the budget is spent, and the budget stops at zero",
         %{project: project} do
      assert {[{%Observation{status: :refused}, text}], 0} =
               Observer.observe([read("lib/nope.ex")], project, 0)

      assert text =~ "error: file not found"
    end

    test "text the model chose is clipped before it is echoed back", %{project: project} do
      long = String.duplicate("a", 5_000)

      text = observe!(read("lib/" <> long), project)

      # Both the echoed request and the reason, which repeats the path.
      assert byte_size(text) < 1_000
      assert text =~ "\nerror: "
    end

    test "only so many requests are run per reply", %{project: project} do
      intents = for _ <- 1..21, do: glob("lib/*.ex")

      {observations, _budget} = Observer.observe(intents, project, @budget)

      assert length(observations) == 21
      assert {%Observation{status: :shown}, text} = Enum.at(observations, 19)
      assert text =~ "2 matches"
      assert {%Observation{status: :refused}, text} = List.last(observations)
      assert text =~ "error: not run"
    end

    test "long listings are cut, saying how much is missing", %{project: project} do
      File.mkdir_p!(Path.join(project, "many"))
      for i <- 1..205, do: File.write!(Path.join(project, "many/f#{i}.txt"), "")

      text = observe!(glob("many/*.txt"), project)

      assert text =~ "205 matches"
      assert text =~ "... 5 more not shown"
    end
  end
end
