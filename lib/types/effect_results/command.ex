defmodule Current.EffectResult.Command do
  @enforce_keys [
    :exit_code,
    :stdout_artifact_id,
    :stderr_artifact_id,
    :stdout_bytes,
    :stderr_bytes
  ]
  defstruct [:exit_code, :stdout_artifact_id, :stderr_artifact_id, :stdout_bytes, :stderr_bytes]

  @type t :: %__MODULE__{
          exit_code: non_neg_integer(),
          stdout_artifact_id: Current.Id.t(),
          stderr_artifact_id: Current.Id.t(),
          stdout_bytes: non_neg_integer(),
          stderr_bytes: non_neg_integer()
        }
end
