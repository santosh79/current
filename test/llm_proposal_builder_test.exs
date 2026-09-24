defmodule Current.LLMProposalBuilderTest do
  use ExUnit.Case, async: false

  alias Current.{BlobStore, FakeLLMClient, Id, LLMProposalBuilder, Proposal, Request}
  alias Current.Error.ProposalProductionError

  @timeout_ms 5_000

  defp request, do: %Request{input: "add email validation", context: %{}}

  describe "build/5 - success" do
    test "returns a decoded proposal and the raw output's blob id" do
      raw = ~s({"intents": [{"type": "run_command", "cmd": "echo"}]})
      FakeLLMClient.set_response({:ok, raw})

      assert {:ok, %Proposal{} = proposal, blob_id} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 File.cwd!()
               )

      assert length(proposal.intents) == 1
      assert {:ok, ^raw} = BlobStore.read(blob_id)
    end
  end

  describe "build/5 - connection failure" do
    test "wraps a client error as stage: :connection" do
      FakeLLMClient.set_response({:error, :econnrefused})

      assert {:error, %ProposalProductionError{stage: :connection, reason: :econnrefused}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 File.cwd!()
               )
    end
  end

  describe "build/5 - project context" do
    defmodule PromptCapturingClient do
      @behaviour Current.LLMClient

      def set_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)

      @impl true
      def complete(prompt, _timeout_ms) do
        send(:persistent_term.get({__MODULE__, :test_pid}), {:prompt, prompt})
        {:ok, ~s({"intents": [{"type": "run_command", "cmd": "echo"}]})}
      end
    end

    setup do
      dir = Path.join(System.tmp_dir!(), "current_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join([dir, "lib", "signup.ex"]), "defmodule Signup do\nend\n")
      File.mkdir_p!(Path.join(dir, "deps/ignored"))
      File.write!(Path.join([dir, "deps", "ignored", "dep.ex"]), "should not appear")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "files under project_dir are included in the prompt", %{dir: dir} do
      PromptCapturingClient.set_test_pid(self())

      assert {:ok, %Proposal{}, _blob_id} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 PromptCapturingClient,
                 @timeout_ms,
                 dir
               )

      assert_receive {:prompt, prompt}
      assert prompt =~ "=== lib/signup.ex ===\ndefmodule Signup do"
      refute prompt =~ "should not appear"
    end

    test "no project_dir at all is a stage: :project_context error, not a read of the cwd" do
      assert {:error, %ProposalProductionError{stage: :project_context, reason: :no_project_dir}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 nil
               )
    end

    test "a project_dir that isn't a directory is a stage: :project_context error", %{dir: dir} do
      assert {:error,
              %ProposalProductionError{stage: :project_context, reason: {:not_a_directory, _}}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 Path.join(dir, "does_not_exist")
               )
    end
  end

  describe "build/5 - timeout" do
    test "returns stage: :timeout when the client never responds, without hanging the test" do
      FakeLLMClient.set_response(:hang)

      assert {:error, %ProposalProductionError{stage: :timeout, reason: reason}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 50,
                 File.cwd!()
               )

      assert reason =~ "50ms"
    end

    test "a client that reports {:error, :timeout} itself also surfaces as stage: :timeout" do
      FakeLLMClient.set_response({:error, :timeout})

      assert {:error, %ProposalProductionError{stage: :timeout}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 File.cwd!()
               )
    end
  end

  describe "build/5 - decode failure" do
    test "wraps a decode error as stage: :decode and preserves the raw output's blob id" do
      raw = "not json at all {{{"
      FakeLLMClient.set_response({:ok, raw})

      assert {:error, %ProposalProductionError{stage: :decode, raw_output_blob_id: blob_id}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 File.cwd!()
               )

      assert {:ok, ^raw} = BlobStore.read(blob_id)
    end

    test "an unknown intent type also surfaces as stage: :decode" do
      raw = ~s({"intents": [{"type": "teleport"}]})
      FakeLLMClient.set_response({:ok, raw})

      assert {:error, %ProposalProductionError{stage: :decode, reason: reason}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 Current.FakeLLMClient,
                 @timeout_ms,
                 File.cwd!()
               )

      assert reason =~ "unknown intent type"
    end
  end

  describe "build/5 - a client that raises never crashes the builder" do
    defmodule RaisingClient do
      @behaviour Current.LLMClient
      @impl true
      def complete(_prompt, _timeout_ms), do: raise("client exploded")
    end

    test "surfaces as a connection-stage error, not an exception" do
      assert {:error, %ProposalProductionError{stage: :connection, reason: reason}} =
               LLMProposalBuilder.build(
                 request(),
                 Id.generate(),
                 RaisingClient,
                 @timeout_ms,
                 File.cwd!()
               )

      assert reason =~ "client exploded"
    end
  end

  describe "build/5 - file_patch diff format" do
    test "the prompt asks for a unified diff that patch accepts, with an example" do
      dir = Path.join(System.tmp_dir!(), "current_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      __MODULE__.PromptCapturingClient.set_test_pid(self())

      # Only the prompt matters here, not what is made of the reply.
      _ =
        LLMProposalBuilder.build(
          request(),
          Id.generate(),
          __MODULE__.PromptCapturingClient,
          @timeout_ms,
          dir
        )

      assert_receive {:prompt, prompt}
      assert prompt =~ "patch --batch --forward --fuzz=0 <path> <diff>"
      # EffectApplicator refuses a write_file whose target exists.
      assert prompt =~ "write_file only ever creates files"
      refute prompt =~ "prefer write_file"
      assert prompt =~ ~s(do NOT use the\n  "*** Begin Patch")
      {_before, example_diff, _after} = LLMProposalBuilder.file_patch_example()
      assert prompt =~ "<diff>\n" <> String.trim_trailing(example_diff) <> "\n</diff>"
    end

    # Applied exactly the way Current.EffectApplicator applies a file_patch.
    test "the example diff in the prompt applies with patch" do
      {before, diff, expected} = LLMProposalBuilder.file_patch_example()

      dir = Path.join(System.tmp_dir!(), "current_example_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      file = Path.join(dir, "greeter.ex")
      patch_file = Path.join(dir, "greeter.diff")
      File.write!(file, before)
      File.write!(patch_file, diff)

      assert {_output, 0} =
               System.cmd("patch", ["--batch", "--forward", "--fuzz=0", file, patch_file],
                 stderr_to_stdout: true
               )

      assert File.read!(file) == expected
    end
  end
end
