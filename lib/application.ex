defmodule Current.Application do
  use Application

  @impl true

  def start(_type, _args) do
    :ok =
      :persistent_term.put(
        :proposal_builder,
        Current.ProposalBuilder
      )

    :ok =
      :persistent_term.put(
        :effect_applicator,
        Current.EffectApplicator
      )

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
