defmodule Current.Proposal do
  @enforce_keys [:id, :workflow_id, :intents]
  defstruct [
    :id,
    :workflow_id,
    :intents,
    :justification,
    :claims,
    :dependencies
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intents: [Current.Intent.t()],
          justification: String.t() | nil,
          claims: [String.t()] | nil,
          dependencies: [String.t()] | nil
        }
end
