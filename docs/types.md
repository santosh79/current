## Core Types

### Task
```elixir
defmodule Current.Task do
  @enforce_keys [:id, :input, :context, :submitted_at]
  defstruct [
    :id,
    :input,
    :context,
    :workflow_id,
    :submitted_at
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          input: String.t() | map(),
          context: map(),
          workflow_id: Current.Id.t() | nil,
          submitted_at: DateTime.t()
        }
end
```

### Workflow
```elixir
defmodule Current.Workflow do
  @enforce_keys [:id, :task_id, :status, :created_at]
  defstruct [
    :id,
    :task_id,
    :status,
    :proposal,
    :workflow_artifact,
    :events,
    :started_at,
    :created_at,
    :completed_at,
    :updated_at,
    :error
  ]

  @type status ::
        :created
        | :planning
        | :validating
        | :waiting_for_approval
        | :approved
        | :applying
        | :assembling_artifact
        | :completed
        | :rejected
        | :failed

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          task_id: Current.Id.t(),
          status: status(),
          proposal: Current.Proposal.t() | nil,
          workflow_artifact: Current.WorkflowArtifact.t() | nil,
          events: [Current.Event.t()],
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          error: String.t() | nil
        }
end
```

### Proposal

```elixir
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
```

### Intent

```elixir
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
```

### ID

```elixir
defmodule Current.Id do
  @type t :: String.t()

  @sha256_prefix "sha256:"
  @sha256_hex_length 64

  def validate(@sha256_prefix <> hex) when byte_size(hex) == @sha256_hex_length do
    if String.match?(hex, ~r/\A[0-9a-f]+\z/) do
      :ok
    else
      {:error, :invalid_id_hex}
    end
  end

  def validate(_), do: {:error, :invalid_id}
end
```

### Artifact

```elixir
defmodule Current.Artifact do
  @enforce_keys [:id, :workflow_id, :type, :storage, :metadata, :timestamp]
  defstruct [
    :id,
    :workflow_id,
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
          name: atom() | nil,
          type: type(),
          storage: storage(),
          metadata: metadata(),
          timestamp: DateTime.t()
        }
end
```

#### ArtifactRef

```elixir
defmodule Current.ArtifactRef do
  @enforce_keys [:id, :workflow_id]
  defstruct [
    :id,
    :name,
    :workflow_id,
    :type
  ]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          name: atom() | nil,
          type: Current.Artifact.type() | nil
        }
end
```

### Event

```elixir
defmodule Current.Event do
  @enforce_keys [:id, :workflow_id, :type, :data, :timestamp]
  defstruct [
    :id,
    :workflow_id,
    :type,
    :data,
    :timestamp
  ]

  @type type ::
          :task_submitted
          | :workflow_created
          | :workflow_started
          | :proposal_produced
          | :approval_requested
          | :proposal_accepted
          | :proposal_rejected
          | :intent_proposed
          | :intent_validated
          | :intent_rejected
          | :effect_applied
          | :effect_failed
          | :artifact_produced
          | :claim_verified
          | :workflow_artifact_assembled
          | :workflow_completed
          | :workflow_failed

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          type: type(),
          data: map(),
          timestamp: DateTime.t()
        }
end
```

### WorkflowArtifact

```elixir
defmodule Current.WorkflowArtifact do
  @enforce_keys [:id, :workflow_id, :type, :artifacts, :created_at]
  defstruct [
    :id,
    :workflow_id,
    :type,
    :artifacts,
    :summary,
    :metadata,
    :created_at
  ]

  @type type ::
          :result_bundle
          | :report
          | :manifest
          | :patch_set
          | :verification_output

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          workflow_id: Current.Id.t(),
          type: type(),
          artifacts: [Current.ArtifactRef.t()],
          summary: String.t() | nil,
          metadata: map() | nil,
          created_at: DateTime.t()
        }
end
```