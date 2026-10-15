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
      # or, to answer each call from the prompt it was given (a model
      # that asks for context first and proposes once it has it):
      Current.FakeLLMClient.set_response(fn prompt -> {:ok, "..."} end)

  Current.LLMProposalBuilder is expected to own its own timeout (see
  Current.ProposalBuilder's @callback doc), so :hang is here specifically
  to let builder-level tests prove that ownership actually works, without
  needing a real slow network call.
  """

  @key {__MODULE__, :response}

  @type response :: {:ok, String.t()} | {:error, term()} | :hang

  @spec set_response(response() | (String.t() -> response())) :: :ok
  def set_response(response) do
    :persistent_term.put(@key, response)
  end

  def provider, do: "fake"

  def list_models(_timeout_ms), do: {:ok, ["model_one_name", "model_two_name"]}

  # The model is ignored: the response is whatever the test set.
  def complete(prompt, _timeout_ms, _model) do
    case :persistent_term.get(@key, {:error, :not_configured}) do
      fun when is_function(fun, 1) -> respond(fun.(prompt))
      response -> respond(response)
    end
  end

  defp respond(:hang), do: Process.sleep(:infinity)
  defp respond(response), do: response
end
