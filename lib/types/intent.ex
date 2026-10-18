defmodule Current.Intent.EditFile do
  @moduledoc """
  Replaces `old_string` with `new_string` in an existing file. Both
  strings are artifacts, like WriteFile's contents. See Current.Edit for
  what counts as a match.
  """

  @enforce_keys [:id, :proposal_id, :path, :old_artifact_id, :new_artifact_id]
  defstruct [:id, :proposal_id, :path, :old_artifact_id, :new_artifact_id, replace_all: false]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          path: String.t(),
          old_artifact_id: Current.Id.t(),
          new_artifact_id: Current.Id.t(),
          replace_all: boolean()
        }
end

defmodule Current.Intent.WriteFile do
  @enforce_keys [:id, :proposal_id, :path, :contents_artifact_id]
  defstruct [:id, :proposal_id, :path, :contents_artifact_id]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          path: String.t(),
          contents_artifact_id: Current.Id.t()
        }
end

defmodule Current.Intent.ReadFile do
  @enforce_keys [:id, :proposal_id, :path]
  defstruct [:id, :proposal_id, :path]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          path: String.t()
        }
end

defmodule Current.Intent.DeleteFile do
  @enforce_keys [:id, :proposal_id, :path]
  defstruct [:id, :proposal_id, :path]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          path: String.t()
        }
end

defmodule Current.Intent.RunCommand do
  @enforce_keys [:id, :proposal_id, :cmd]
  defstruct [:id, :proposal_id, :cmd, args: []]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          cmd: String.t(),
          args: [String.t()]
        }
end

defmodule Current.Intent.Grep do
  @enforce_keys [:id, :proposal_id, :pattern, :paths]
  defstruct [:id, :proposal_id, :pattern, :paths]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          pattern: String.t(),
          paths: [String.t()]
        }
end

defmodule Current.Intent.Glob do
  @enforce_keys [:id, :proposal_id, :pattern]
  defstruct [:id, :proposal_id, :pattern, base_dir: "."]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          pattern: String.t(),
          base_dir: String.t()
        }
end

defmodule Current.Intent.Claim do
  @enforce_keys [:id, :proposal_id, :statement]
  defstruct [:id, :proposal_id, :statement, :evidence, :expected]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          statement: String.t(),
          evidence: Current.EffectResult.Claim.evidence() | nil,
          expected: boolean() | nil
        }
end

defmodule Current.Intent.Report do
  @enforce_keys [:id, :proposal_id]
  defstruct [:id, :proposal_id, :summary]

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          proposal_id: Current.Id.t(),
          summary: String.t() | nil
        }
end

defmodule Current.Intent do
  @type t ::
          Current.Intent.EditFile.t()
          | Current.Intent.WriteFile.t()
          | Current.Intent.DeleteFile.t()
          | Current.Intent.RunCommand.t()
          | Current.Intent.ReadFile.t()
          | Current.Intent.Glob.t()
          | Current.Intent.Grep.t()
          | Current.Intent.Claim.t()
          | Current.Intent.Report.t()

  @known_modules [
    Current.Intent.ReadFile,
    Current.Intent.WriteFile,
    Current.Intent.DeleteFile,
    Current.Intent.EditFile,
    Current.Intent.RunCommand,
    Current.Intent.Glob,
    Current.Intent.Grep,
    Current.Intent.Claim,
    Current.Intent.Report
  ]

  @spec modules() :: [module()]
  def modules, do: @known_modules

  def valid?(%{__struct__: mod}), do: mod in @known_modules
  def valid?(_), do: false
end
