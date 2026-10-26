defmodule Current.LLMClient do
  @moduledoc """
  The contract between Current and a model provider.

  Clients are plain modules, not processes: they hold no state (the API
  key is read from the environment per call), each call is one HTTP
  request, and isolation and the deadline are the caller's
  (Current.LLMProposalBuilder runs every call in its own Task).

  Expected failures -- no API key, provider down, HTTP error, truncated
  output -- are returned as `{:error, reason}`, never raised.
  """

  @type role :: :system | :user | :assistant
  @type message :: %{role: role(), content: String.t()}

  @type usage :: %{
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer(),
          optional(:cache_creation_input_tokens) => non_neg_integer(),
          optional(:cache_read_input_tokens) => non_neg_integer()
        }

  @type completion :: %{text: String.t(), usage: usage() | nil}

  @callback provider() :: String.t()

  @callback complete(messages :: [message()], timeout_ms :: pos_integer(), model_id :: String.t()) ::
              {:ok, completion()} | {:error, term()}

  @callback list_models(timeout_ms :: pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
end
