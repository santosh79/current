defmodule Current.RuntimeSupervisor do
  @moduledoc """
  Supervises one complete incarnation of the Current runtime.

  The consensus WAL is the runtime's durable authority. It starts first
  and replays synchronously before any other runtime component starts.

  If the WAL process terminates, this supervisor shuts down the entire
  runtime. Its parent, Current.Supervisor, may then start a fresh runtime
  incarnation, which begins by reopening and replaying the WAL.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(
      __MODULE__,
      opts,
      name: __MODULE__
    )
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:current, :http, [])

    children =
      [
        Supervisor.child_spec(
          Current.Consensus.Log,
          restart: :temporary,
          significant: true
        ),
        Current.Consensus.FailedEventsLog,
        Supervisor.child_spec(
          {Registry, keys: :duplicate, name: Current.EventRegistry},
          restart: :temporary,
          significant: true
        ),
        Supervisor.child_spec(
          Current.EventStore,
          restart: :temporary,
          significant: true
        ),
        Current.Consensus.Supervisor,
        Current.TaskStore,
        Current.ProposalStore,
        Current.WorkflowStore,
        {
          DynamicSupervisor,
          name: Current.WorkflowSupervisor, strategy: :one_for_one
        },
        Current.ModelCatalog,
        Current.TaskDispatcher
      ]

    children =
      case Keyword.get(config, :enabled, true) do
        true -> children ++ Current.HTTP.Server.children()
        _ -> children
      end

    Supervisor.init(
      children,
      strategy: :one_for_one,
      auto_shutdown: :any_significant
    )
  end
end
