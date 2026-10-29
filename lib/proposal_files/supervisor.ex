defmodule Current.ProposalFiles.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [Current.ProposalFiles],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
