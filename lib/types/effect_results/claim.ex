defmodule Current.EffectResult.Claim do
  @enforce_keys [:verified, :statement]
  defstruct [:verified, :statement, :reason, :evidence]

  @type condition ::
          :match_count_greater_than
          | :match_count_equals
          | :exit_code_equals

  @type evidence :: %{
          source_intent_id: Current.Id.t(),
          condition: condition(),
          value: term()
        }

  @type t :: %__MODULE__{
          verified: boolean(),
          statement: String.t(),
          reason: String.t() | nil,
          evidence: evidence() | nil
        }
end

