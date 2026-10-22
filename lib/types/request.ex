defmodule Current.Request do
  @moduledoc """
  What the user asked for. Where it runs -- the project directory -- is
  execution context, not request content: it is passed to
  Current.submit_task/3, recorded on TaskCreated, and handed by
  WorkflowOrchestrator to each step that needs it.

  `model` is required: one entry of Current.ModelCatalog.all/0
  (`"provider:model_id"`). There is no default client or model.
  Current.submit_task/3 checks it against the catalog and records it on
  TaskCreated; WorkflowOrchestrator rebuilds the request with it from
  that record.
  """

  @enforce_keys [:input, :context, :model]
  defstruct [
    :input,
    :context,
    :model,
    mode: Current.Mode.default(),
    # nil: the runtime's own bound on producing a proposal.
    timeout_ms: nil,
    # nil for a first proposal. On a revision: every proposal so far and
    # every round of reviewer feedback, oldest first. Built by
    # WorkflowOrchestrator from the log; never persisted on its own.
    revision: nil
  ]

  @type revision :: %{previous: [Current.Proposal.t()], feedback: [String.t()]}

  @type t :: %__MODULE__{
          input: String.t() | map(),
          context: map(),
          model: Current.ModelCatalog.model_name(),
          mode: Current.Mode.t(),
          timeout_ms: pos_integer() | nil,
          revision: revision() | nil
        }
end
