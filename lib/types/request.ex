defmodule Current.Request do
  @moduledoc """
  What the user asked for. Where it runs -- the project directory -- is
  execution context, not request content: it is passed to
  Current.submit_task/3, recorded on TaskCreated, and handed by
  WorkflowOrchestrator to each step that needs it.
  """

  @enforce_keys [:input, :context]
  defstruct [
    :input,
    :context,
    mode: Current.Mode.default()
  ]

  @type t :: %__MODULE__{
          input: String.t() | map(),
          context: map(),
          mode: Current.Mode.t()
        }
end
