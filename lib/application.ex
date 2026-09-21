defmodule Current.Application do
  use Application

  @impl true

  def start(_type, _args) do
    children = [
      Current.RuntimeSupervisor
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Current.Supervisor
    )
  end
end
