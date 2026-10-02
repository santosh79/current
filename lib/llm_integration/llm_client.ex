defmodule Current.LLMClient do
  @moduledoc """
  The boundary between Current and whatever actually talks to a model.

  A client is a plain module: it takes a prompt, a timeout and the
  model to run it on, and returns the model's raw text response or an
  error. The model is always named by the caller; a client has no
  default of its own. Implementations can also enumerate the models
  available to their configured credentials.

  The timeout is supplied by the caller; clients hold no timeout policy
  of their own. A client that gives up because the timeout elapsed
  returns `{:error, :timeout}`, so callers can tell a timeout apart from
  other failures without knowing anything about the client's transport.
  """

  @type prompt :: String.t()
  @type timeout_ms :: pos_integer()
  @type model_id :: String.t()

  @doc """
  Completes `prompt` on `model`.

  The model is a provider-native ID, as `list_models/1` returns them --
  not a provider-qualified Current.ModelCatalog entry.
  """
  @callback complete(prompt(), timeout_ms(), model_id()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Lists model IDs available from this provider to the configured credentials.

  Returned names are provider-native IDs, such as `"gpt-5.6"` or
  `"claude-opus-5-5"`. They are not provider-qualified: callers that want
  `"openai/gpt-5.6"` or `"anthropic/claude-opus-5-5"` should add that
  namespace themselves.
  """
  @callback list_models(timeout_ms()) :: {:ok, [model_id()]} | {:error, term()}

  @doc """
  Human readable name of the model provider
  """
  @callback provider() :: String.t()
end
