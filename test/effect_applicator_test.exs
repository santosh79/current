defmodule Current.EffectApplicatorTest do
  use ExUnit.Case, async: false

  alias Current.{EffectApplicator, Id, Intent}

  defp intent_fixture(type, payload) do
    %Intent{
      id: Id.generate(),
      proposal_id: Id.generate(),
      type: type,
      payload: payload
    }
  end

  describe "apply/1 - file_patch" do
    setup do
      dir = System.tmp_dir!() |> Path.join("effect_applicator_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "applies a unified diff to an existing file", %{dir: dir} do
      path = Path.join(dir, "signup.ex")
      File.write!(path, "defmodule Signup do\nend\n")

      diff = """
      --- a/signup.ex
      +++ b/signup.ex
      @@ -1,2 +1,3 @@
       defmodule Signup do
      +  def validate_email(email), do: String.contains?(email, "@")
       end
      """

      intent = intent_fixture(:file_patch, %{path: path, diff: diff})
      assert {:ok, result} = EffectApplicator.apply(intent)

      assert result.path == path
      contents = File.read!(path)
      assert contents =~ "def validate_email"
    end

    test "returns error if the file does not exist", %{dir: dir} do
      path = Path.join(dir, "nonexistent.ex")
      intent = intent_fixture(:file_patch, %{path: path, diff: "--- a\n+++ b\n"})
      assert {:error, reason} = EffectApplicator.apply(intent)
      assert reason =~ "not found" or reason =~ "no such file"
    end

    test "returns error if the diff does not apply cleanly", %{dir: dir} do
      path = Path.join(dir, "app.ex")
      File.write!(path, "defmodule App do\nend\n")

      bad_diff = """
      --- a/app.ex
      +++ b/app.ex
      @@ -1,2 +1,3 @@
       defmodule WrongModule do
      +  def foo, do: :bar
       end
      """

      intent = intent_fixture(:file_patch, %{path: path, diff: bad_diff})
      assert {:error, _reason} = EffectApplicator.apply(intent)
    end
  end

  # describe "apply/1 - unsupported intent type" do
  #   test "returns error with descriptive message" do
  #     intent = intent_fixture(:drop_database, %{})
  #     assert {:error, reason} = EffectApplicator.apply(intent)
  #     assert reason =~ "unsupported intent type"
  #     assert reason =~ "drop_database"
  #   end

  #   test "error message includes the actual intent type" do
  #     intent = intent_fixture(:launch_missiles, %{})
  #     {:error, reason} = EffectApplicator.apply(intent)
  #     assert reason =~ "launch_missiles"
  #   end
  # end

  # describe "apply/1 - run_command" do
  #   test "executes the command and returns exit code 0 on success" do
  #     intent = intent_fixture(:run_command, %{command: "echo hello"})
  #     assert {:ok, result} = EffectApplicator.apply(intent)
  #     assert result.exit_code == 0
  #     assert result.stdout =~ "hello"
  #   end

  #   test "returns non-zero exit code on failure" do
  #     intent = intent_fixture(:run_command, %{command: "exit 1"})
  #     assert {:ok, result} = EffectApplicator.apply(intent)
  #     assert result.exit_code != 0
  #   end

  #   test "captures stderr output" do
  #     intent = intent_fixture(:run_command, %{command: "echo error >&2"})
  #     assert {:ok, result} = EffectApplicator.apply(intent)
  #     assert is_binary(result.stderr)
  #   end

  #   test "returns error if command is not found" do
  #     intent = intent_fixture(:run_command, %{command: "this_command_does_not_exist_xyz"})
  #     assert {:error, _reason} = EffectApplicator.apply(intent)
  #   end
  # end
end
