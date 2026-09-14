defmodule Current.Consensus do
  @moduledoc """
  The application's one entry point into consensus. Everything else in
  Current -- the orchestrator, submit_task/2, review_proposal/2 -- calls
  propose/1 and nothing else; none of it knows or should know that the
  current implementation is a single-node stand-in
  (Current.Consensus.SingleNodeServer). Swapping in a real Raft/Paxos
  implementation later is a change to this module alone.
  """

  @server Current.Consensus.SingleNodeServer

  @doc """
  Proposes one event or a batch of events to consensus.

  Returns :ok once the proposal has been accepted by consensus -- not
  once the event is canonical in EventStore. Confirmation of that arrives
  later, the same way every other committed event does: as
  {:event_committed, entry} to whoever is subscribed via
  Current.EventNotifier.subscribe/2,3.
  """
  @spec propose(Current.Event.t() | [Current.Event.t()]) ::
          :ok | {:error, term()}
  def propose(events) do
    Current.Consensus.SingleNodeServer.propose(@server, events)
  end
end
