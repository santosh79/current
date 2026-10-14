defmodule Current.LLMIntegration.OpenAILiveTest do
  use ExUnit.Case, async: false

  alias Current.{LLMProposalBuilder, Proposal, Request}

  @moduletag :live_llm

  @timeout_ms 240_000

  # A tiny, known project for the model to look at, instead of whatever
  # happens to be in the repo checkout.
  @project_files %{
    "README.md" => """
    # greeter

    A tiny Elixir library that greets people.
    """,
    "mix.exs" => """
    defmodule Greeter.MixProject do
      use Mix.Project

      def project do
        [app: :greeter, version: "0.1.0", elixir: "~> 1.18"]
      end
    end
    """,
    "lib/greeter.ex" => """
    defmodule Greeter do
      def hello(name) do
        "Hello, " <> name
      end
    end
    """
  }

  setup do
    project_dir =
      Path.join(
        Current.TestTmp.dir(),
        "current_live_llm_#{System.unique_integer([:positive])}"
      )

    for {path, contents} <- @project_files do
      full_path = Path.join(project_dir, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, contents)
    end

    on_exit(fn ->
      File.rm_rf!(project_dir)
    end)

    {:ok, project_dir: project_dir}
  end

  test "list_models" do
    {:ok, pid} = Current.LLMClient.OpenAI.start_link([])
    {:ok, models} = Current.LLMClient.OpenAI.list_models(pid, 10_000)
    assert length(models) > 1
    :ok = GenServer.stop(pid, :normal)
  end

  test "OpenAI produces a proposal that Current can decode", %{project_dir: project_dir} do
    case System.get_env("OPENAI_API_KEY") in [nil, ""] do
      true -> flunk("OPENAI_API_KEY must be set to run live LLM tests")
      _ -> :ok
    end

    request = %Request{
      input: "Produce a report saying that the live LLM integration test succeeded.",
      context: %{},
      model: "openai:gpt-5.6",
      mode: :plan
    }

    workflow_id = Current.Id.generate()

    assert {:ok, %Proposal{} = proposal, raw_output_blob_id} =
             LLMProposalBuilder.build(
               request,
               workflow_id,
               Current.LLMClient.OpenAI,
               @timeout_ms,
               project_dir
             )

    assert proposal.workflow_id == workflow_id
    assert proposal.intents != []

    assert {:ok, raw_output} =
             Current.BlobStore.read(raw_output_blob_id)

    assert is_binary(raw_output)
    assert byte_size(raw_output) > 0
  end
end
