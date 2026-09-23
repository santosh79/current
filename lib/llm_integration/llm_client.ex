defmodule Current.LLMClient do
  @moduledoc """
  The boundary between Current and whatever actually talks to a model.

  Deliberately tiny: one function, one job -- take a prompt and a
  timeout, return the model's raw text response or an error.

  The timeout is supplied by the caller; clients hold no timeout policy
  of their own. A client that gives up because the timeout elapsed
  returns `{:error, :timeout}`, so callers can tell a timeout apart from
  other failures without knowing anything about the client's transport.
  """

  @type prompt :: String.t()
  @type timeout_ms :: pos_integer()

  @callback complete(prompt(), timeout_ms()) :: {:ok, String.t()} | {:error, term()}
end
