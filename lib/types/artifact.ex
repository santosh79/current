defmodule Current.Artifact do
  @enforce_keys [:id, :workflow_id, :intent_id, :type, :storage, :metadata, :timestamp]
  defstruct [
    :id,
    :workflow_id,
    :intent_id,
    :name,
    :type,
    :storage,
    :metadata,
    :timestamp
  ]

  @type type ::
          :file_patch_result
          | :command_result
          | :test_result
          | :read_result
          | :claim_result
          | :report
          | :manifest

  @type storage :: %{
          backend: :filesystem,
          path: String.t()
        }

  @type metadata :: %{
          optional(:bytes) => non_neg_integer(),
          optional(:content_type) => String.t()
        }

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          intent_id: Current.Id.t(),
          name: atom() | nil,
          type: type(),
          storage: storage(),
          metadata: metadata(),
          timestamp: DateTime.t()
        }
end
