defmodule Current.Consensus.Supervisor do
  @moduledoc """
  Supervises the runtime consensus pipeline:

      SingleNodeServer -> EventCommitter
                       -> ActivityLog (console output of each commit)

  Current.Consensus.Log is owned directly by Current.Supervisor now (as
  a significant, :temporary child started before this supervisor), not
  by this one -- it must already be fully initialized, with the WAL
  open and replayed, before SingleNodeServer.init/1 can read a durable
  head from it. `:rest_for_one` here covers the remaining dependency:
  EventCommitter holds a call-time subscription to SingleNodeServer, so
  it must be restarted and re-subscribe whenever SingleNodeServer is
  replaced.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Current.Consensus.SingleNodeServer,
       name: Current.Consensus.SingleNodeServer, log: Current.Consensus.Log},
      {Current.EventCommitter,
       name: Current.EventCommitter, consensus: Current.Consensus.SingleNodeServer},
      # Also subscribes to SingleNodeServer, so it sits after it too.
      {Current.ActivityLog, consensus: Current.Consensus.SingleNodeServer}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
