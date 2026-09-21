defmodule Current.LLMClient do
  @moduledoc """
  The boundary between Current and whatever actually talks to a model.

  Deliberately tiny: one function, one job -- take a prompt, return the
  model's raw text response or an error.
  """

  @type prompt :: String.t()

  @callback complete(prompt()) :: {:ok, String.t()} | {:error, term()}
end
