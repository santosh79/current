defmodule Current.Observation do
  @moduledoc """
  One thing an agent asked to look at before proposing, and what came of
  it.

  An agent is given a project's layout, not its contents. To see more it
  replies with observations instead of a proposal (see the wire schema's
  `context_request`). Each one wraps a single read-only intent --
  `read_file`, `glob` or `grep` -- and may say why the agent wants it.

  The agent writes the request half: `intent` and `reason`. The runtime
  fills in the rest:

    * Current.ProposalDecoder gives it an `id`; it starts out
      `:requested`.
    * Current.LLMProposalBuilder records which of the agent's replies
      asked for it: `round` (1 for the first reply that asked for
      context) and `reply_artifact_id` (that reply, untouched).
    * Current.Observer runs the intent under the runtime's file-access
      rules and settles it: `:shown`, with `artifact_id` leading to what
      the agent was shown, or `:refused`, with `error` saying why it was
      shown nothing.

  Like an intent, an observation never holds contents -- only the id of
  the artifact that does. That keeps it small enough to live inside the
  proposal it led to (`Current.Proposal.observations`), and so inside the
  event log.
  """

  alias Current.Intent

  @enforce_keys [:id, :intent]
  defstruct [
    :id,
    :intent,
    :reason,
    :round,
    :reply_artifact_id,
    :artifact_id,
    :error,
    status: :requested
  ]

  @typedoc "The read-only intents an observation may wrap."
  @type intent :: Intent.ReadFile.t() | Intent.Glob.t() | Intent.Grep.t()

  @type status :: :requested | :shown | :refused

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          # As the agent wrote it: paths are relative to the project and
          # not yet resolved. Its proposal_id is nil until the observation
          # is attached to the proposal it led to.
          intent: intent(),
          # Why the agent wanted to see this, in its own words.
          reason: String.t() | nil,
          round: pos_integer() | nil,
          reply_artifact_id: Current.Id.t() | nil,
          status: status(),
          # For read_file the file's contents exactly as read; for glob
          # and grep the listing as it was shown. nil unless :shown.
          artifact_id: Current.Id.t() | nil,
          # nil unless :refused.
          error: String.t() | nil
        }

  @observable [Intent.ReadFile, Intent.Glob, Intent.Grep]

  @doc "Whether `intent` is one an observation may wrap."
  @spec observable?(term()) :: boolean()
  def observable?(%mod{}), do: mod in @observable
  def observable?(_other), do: false

  @doc "The observation, settled: the agent was shown the artifact."
  @spec shown(t(), Current.Id.t()) :: t()
  def shown(%__MODULE__{} = observation, artifact_id) when is_binary(artifact_id),
    do: %{observation | status: :shown, artifact_id: artifact_id, error: nil}

  @doc "The observation, settled: the agent was shown nothing, and why."
  @spec refused(t(), String.t()) :: t()
  def refused(%__MODULE__{} = observation, error) when is_binary(error),
    do: %{observation | status: :refused, artifact_id: nil, error: error}
end
