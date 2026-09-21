defmodule Current.LLMProposalBuilder do
  @moduledoc """
  Wires the LLM boundary together: Current.LLMClient (talks to the
  model, owns nothing about Current's vocabulary) -> BlobStore (raw
  response preserved for provenance, always, success or failure) ->
  Current.ProposalDecoder (untrusted bytes -> typed Proposal.t()).

  Per Current.ProposalBuilder's @callback contract, this module owns its
  own crash and timeout handling completely -- WorkflowOrchestrator no
  longer enforces either (see start_proposal_production/1). A client
  call that hangs, raises, or returns garbage must never escape this
  module as anything other than {:ok, ...} or
  {:error, %Current.Error.ProposalProductionError{}}.
  """

  @behaviour Current.ProposalBuilder

  alias Current.{BlobStore, Proposal, ProposalDecoder, Request}
  alias Current.Error.ProposalProductionError

  @default_timeout_ms 30_000

  @impl true
  @spec build(Request.t(), Current.Id.t(), module()) ::
          {:ok, Proposal.t()}
          | {:ok, Proposal.t(), Current.Id.t()}
          | {:error, ProposalProductionError.t()}
  def build(%Request{} = req, workflow_id, client) do
    prompt = prompt_for(req)

    case call_with_timeout(client, prompt) do
      {:ok, raw} ->
        decode(raw, workflow_id)

      {:error, :timeout} ->
        {:error,
         %ProposalProductionError{
           stage: :timeout,
           reason: "no response after #{timeout_ms()}ms"
         }}

      {:error, reason} ->
        {:error,
         %ProposalProductionError{
           stage: :connection,
           reason: reason
         }}
    end
  end

  ## --- Client call, with a bound this module owns end to end -----------

  defp call_with_timeout(client, prompt) do
    task = Task.async(fn -> safe_complete(client, prompt) end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Task.async/1 re-raises inside the caller on Task.yield/2 if the
  # task's function raised -- catching here, inside the task itself,
  # keeps a misbehaving client from ever propagating as an exception at
  # all, rather than relying on a caller-side rescue.
  defp safe_complete(client, prompt) do
    client.complete(prompt)
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp timeout_ms do
    Application.get_env(:current, :llm_proposal_timeout_ms, @default_timeout_ms)
  end

  ## --- Decode + provenance ------------------------------------------------

  defp decode(raw, workflow_id) do
    {:ok, raw_output_blob_id} = BlobStore.put(raw)

    case ProposalDecoder.decode(raw, workflow_id) do
      {:ok, %Proposal{} = proposal} ->
        {:ok, proposal, raw_output_blob_id}

      {:error, reason} ->
        {:error,
         %ProposalProductionError{
           stage: :decode,
           reason: reason,
           raw_output_blob_id: raw_output_blob_id
         }}
    end
  end

  ## --- Prompt -----------------------------------------------------------

  defp prompt_for(%Request{input: input, context: context}) do
    """
    You are Current, an agent that proposes structured changes to a codebase.

    Request: #{inspect(input)}
    Context: #{inspect(context)}

    Respond with a single JSON object matching the schema described below.
    Return nothing but that JSON object -- no prose, no markdown fences.

    #{Current.ProposalWireSchema.raw()}
    """
  end
end
