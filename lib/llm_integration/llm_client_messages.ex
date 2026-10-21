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
