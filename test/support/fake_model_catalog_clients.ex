defmodule Current.TestOpenAIModelCatalogClient do
  @moduledoc false
  # The test configuration's catalog clients: they decide which models
  # exist in tests ("openai:gpt-5.6", ...) and which client a task's
  # model resolves to. Completions go to Current.FakeLLMClient, so
  # FakeLLMClient.set_response/1 controls what "the model" says.

  def provider, do: "openai"

  def start_link([]) do
    pid = spawn(fn -> :ok end)
    {:ok, pid}
  end

  def list_models(_pid, _timeout_ms), do: {:ok, ["gpt-5.6", "gpt-5.6-sol"]}

  defdelegate complete(pid, prompt, timeout_ms, model), to: Current.FakeLLMClient
end

defmodule Current.TestAnthropicModelCatalogClient do
  @moduledoc false

  def provider, do: "anthropic"

  def start_link([]) do
    pid = spawn(fn -> :ok end)
    {:ok, pid}
  end

  def list_models(_pid, _timeout_ms), do: {:ok, ["claude-opus-5-5", "claude-sonnet-4-5"]}

  defdelegate complete(pid, prompt, timeout_ms, model), to: Current.FakeLLMClient
end
