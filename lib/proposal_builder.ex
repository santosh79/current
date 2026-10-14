defmodule Current.ProposalBuilder do
  @moduledoc """
  Produces a proposal for a request. Everything besides the request itself
  is execution context supplied by WorkflowOrchestrator: the LLM client
  module, the timeout for one call to the model, and the task's recorded
  project directory -- nil for a task recorded before project_dir existed,
  which the orchestrator never passes on (it abandons the workflow instead).

  A builder may call the model more than once for one proposal; bounding
  the build as a whole is the builder's own job (see
  Current.LLMProposalBuilder.task_timeout_ms/0).
  """

  @callback build(
              Current.Request.t(),
              Current.Id.t(),
              module(),
              pos_integer(),
              project_dir :: Path.t() | nil
            ) ::
              {:ok, Current.Proposal.t()}
              | {:ok, Current.Proposal.t(), Current.Id.t()}
              | {:error, Current.Error.ProposalProductionError.t()}
end
