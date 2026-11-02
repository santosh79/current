defmodule Current.LLMIntegration.LocalProposalTest do
  use ExUnit.Case, async: false

  import Current.TestHelpers, only: [request: 1]

  alias Current.Error.ProposalProductionError
  alias Current.LLMProposalBuilder

  defmodule Client do
    @moduledoc false
    # A model that never answers, to see which bound ends the build.
    def complete(_messages, timeout, model) do
      send(Application.fetch_env!(:current, :local_proposal_test_owner), {:call, timeout, model})
      Process.sleep(:infinity)
    end
  end

  @timeout_vars ~w(CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS)

  setup do
    saved = for key <- @timeout_vars, do: {key, System.get_env(key)}
    for {key, _} <- saved, do: System.delete_env(key)

    previous_owner = Application.fetch_env(:current, :local_proposal_test_owner)
    Application.put_env(:current, :local_proposal_test_owner, self())

    on_exit(fn ->
      for {key, value} <- saved do
        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end

      case previous_owner do
        {:ok, value} -> Application.put_env(:current, :local_proposal_test_owner, value)
        :error -> Application.delete_env(:current, :local_proposal_test_owner)
      end
    end)

    # An empty project of its own: the build reads the directory's layout, and
    # these tests are about timeouts, not about how long a big tmp dir takes.
    dir = Path.join(Current.TestTmp.dir(), "local_proposal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "the local per-call timeout replaces the runtime's and model ids keep their colons", %{
    dir: dir
  } do
    System.put_env("CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS", "100")
    System.put_env("CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS", "5000")
    request = request(model: "local:coder:latest", mode: :plan)

    assert {:error, %ProposalProductionError{stage: :timeout, reason: "no response after 100ms"}} =
             LLMProposalBuilder.build(request, "local-test", Client, 5_000, dir)

    assert_received {:call, 100, "coder:latest"}
  end

  test "the local whole-task timeout applies, but an explicit task timeout wins", %{dir: dir} do
    System.put_env("CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS", "5000")
    System.put_env("CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS", "100")
    request = request(model: "local:coder", mode: :plan)

    assert {:error, %ProposalProductionError{stage: :timeout, reason: "no proposal after 100ms"}} =
             LLMProposalBuilder.build(request, "local-test", Client, 5_000, dir)

    request = %{request | timeout_ms: 200}

    assert {:error, %ProposalProductionError{stage: :timeout, reason: "no proposal after 200ms"}} =
             LLMProposalBuilder.build(request, "local-test", Client, 5_000, dir)
  end

  test "invalid local timeouts fail before calling the model", %{dir: dir} do
    System.put_env("CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS", "banana")
    request = request(model: "local:coder", mode: :plan)

    assert {:error,
            %ProposalProductionError{
              stage: :connection,
              reason: {:invalid_local_llm_setting, "TASK_TIMEOUT_MS"}
            }} = LLMProposalBuilder.build(request, "invalid-timeout", Client, 5_000, dir)

    refute_received {:call, _, _}

    assert ProposalProductionError.message(%ProposalProductionError{
             stage: :connection,
             reason: {:invalid_local_llm_setting, "TASK_TIMEOUT_MS"}
           }) == "invalid self-hosted model setting CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS"
  end

  test "hosted models ignore the local timeouts", %{dir: dir} do
    System.put_env("CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS", "100")
    System.put_env("CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS", "100")
    request = %{request(model: "openai:gpt-5.6", mode: :plan) | timeout_ms: 300}

    assert {:error, %ProposalProductionError{stage: :timeout, reason: "no proposal after 300ms"}} =
             LLMProposalBuilder.build(request, "hosted-test", Client, 5_000, dir)

    assert_received {:call, 5_000, "gpt-5.6"}
  end

  test "length and max_tokens truncation get the same actionable message" do
    for reason <- [:length, :max_tokens] do
      error = %ProposalProductionError{stage: :connection, reason: {:truncated, reason, 42}}

      assert ProposalProductionError.message(error) ==
               "model response was truncated at 42 output tokens; increase the provider's output limit"
    end
  end
end
