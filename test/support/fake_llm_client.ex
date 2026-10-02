defmodule Current.FakeLLMClient do
  @moduledoc """
  A test-only LLMClient controlled from the test process via
  :persistent_term, so each test can dictate exactly what "the model"
  says without touching the network.

  Usage:

      Current.FakeLLMClient.set_response({:ok, ~s({"intents": []})})
      # or
      Current.FakeLLMClient.set_response({:error, :econnrefused})
      # or, to simulate a client that never returns:
      Current.FakeLLMClient.set_response(:hang)

  Current.LLMProposalBuilder is expected to own its own timeout (see
  Current.ProposalBuilder's @callback doc), so :hang is here specifically
  to let builder-level tests prove that ownership actually works, without
  needing a real slow network call.
  """

  @behaviour Current.LLMClient

  @key {__MODULE__, :response}

  @spec set_response({:ok, String.t()} | {:error, term()} | :hang) :: :ok
  def set_response(response) do
    :persistent_term.put(@key, response)
  end

  @impl true
  def provider, do: "fake"

  @impl true
  def list_models(_timeout_ms), do: {:ok, ["model_one_name", "model_two_name"]}

  # The model is ignored: the response is whatever the test set.
  @impl true
  def complete(_prompt, _timeout_ms, _model) do
    case :persistent_term.get(@key, {:error, :not_configured}) do
      :hang -> Process.sleep(:infinity)
      response -> response
    end
  end
end
