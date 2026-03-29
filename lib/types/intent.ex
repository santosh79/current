defmodule Current.Intent do
  @enforce_keys [:id, :type, :proposal_id, :payload]
  defstruct [
    :id,
    :proposal_id,
    :type,
    :payload
  ]

  @type type ::
          :file_patch
          | :write_file
          | :delete_file
          | :run_command
          | :read_file
          | :glob
          | :grep
          | :claim
          | :report

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          type: type(),
          payload: map()
        }
end
