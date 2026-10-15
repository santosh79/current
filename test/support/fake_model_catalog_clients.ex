defmodule Current.TestOpenAIModelCatalogClient do
  @moduledoc false
  # The test configuration's catalog clients: they decide which models
  # exist in tests ("openai:gpt-5.6", ...) and which client a task's
  # model resolves to. Completions go to Current.FakeLLMClient, so
  # FakeLLMClient.set_response/1 controls what "the model" says.
  @behaviour Current.LLMClient

  @impl true
  def provider, do: "openai"

  @impl true
  def list_models(_timeout_ms), do: {:ok, ["gpt-5.6", "gpt-5.6-sol"]}

  @impl true
  defdelegate complete(prompt, timeout_ms, model), to: Current.FakeLLMClient
end

defmodule Current.TestAnthropicModelCatalogClient do
  @moduledoc false
  @behaviour Current.LLMClient

  @impl true
  def provider, do: "anthropic"

  @impl true
  def list_models(_timeout_ms), do: {:ok, ["claude-opus-5-5", "claude-sonnet-4-5"]}

  @impl true
  defdelegate complete(prompt, timeout_ms, model), to: Current.FakeLLMClient
end

