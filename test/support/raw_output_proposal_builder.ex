defmodule Current.RawOutputProposalBuilder do
  @moduledoc """
  A test-only builder: FakeProposalBuilder's proposal, plus a recorded raw
  model output, as a real LLM-backed builder would return.
  """

  @behaviour Current.ProposalBuilder

  @raw ~s({"justification": "raw model output for tests", "intents": []})

  def raw, do: @raw

  @impl true
  def build(req, workflow_id, client_module, timeout_ms, project_dir) do
    {:ok, proposal} =
      Current.FakeProposalBuilder.build(req, workflow_id, client_module, timeout_ms, project_dir)

    {:ok, raw_output_blob_id} = Current.BlobStore.put(@raw)
    {:ok, proposal, raw_output_blob_id}
  end
end
