defmodule Current.Consensus.Commit do
  @enforce_keys [
    :index,
    :events,
    :previous_hash
  ]

  defstruct [
    :index,
    :events,
    :previous_hash
  ]

  @type t :: %__MODULE__{
          index: pos_integer(),
          events: [Current.Event.t()],
          previous_hash: binary() | nil
        }

  @spec new(pos_integer(), [Current.Event.t()], binary() | nil) :: t()
  def new(index, events, previous_hash) do
    %__MODULE__{
      index: index,
      events: events,
      previous_hash: previous_hash
    }
  end

  @spec hash(t()) :: binary()
  def hash(%__MODULE__{} = commit) do
    commit
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end
end
