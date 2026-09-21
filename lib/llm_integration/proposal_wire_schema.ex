defmodule Current.ProposalWireSchema do
  @moduledoc """
  The canonical wire schema for model-produced proposals.

  `priv/schema/proposal_response.schema.json` is the single source of truth.
  """

  @external_resource schema_path =
                       Path.join(
                         :code.priv_dir(:current),
                         "schema/proposal_response.schema.json"
                       )

  @schema File.read!(schema_path)

  @spec raw() :: String.t()
  def raw, do: @schema
end
