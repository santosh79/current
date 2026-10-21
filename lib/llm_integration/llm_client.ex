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

  @callback provider() :: String.t()

  @callback complete(messages :: [message()], timeout_ms :: pos_integer(), model_id :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback list_models(timeout_ms :: pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
end

defmodule Current.LLMClient.Messages do
  @moduledoc "Helpers shared by clients. A leading :system message is optional."

  @spec split_system([Current.LLMClient.message()]) ::
          {String.t() | nil, [Current.LLMClient.message()]}
  def split_system([%{role: :system, content: system} | rest]), do: {system, rest}
  def split_system(messages), do: {nil, messages}

  @spec encode([Current.LLMClient.message()]) :: [map()]
  def encode(messages) do
    Enum.map(messages, &%{"role" => Atom.to_string(&1.role), "content" => &1.content})
  end
end
