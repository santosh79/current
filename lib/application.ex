defmodule Current.Application do
  use Application

  def start(_type, _args) do
    children = [
      Current.RuntimeRegistry,
      Current.TaskStore,
      Current.WorkflowStore,
      Current.EventStore,
      Current
    ]

    :ok = :persistent_term.put(:proposal_builder, Current.ProposalBuilder)
    :ok = :persistent_term.put(:effect_applicator, Current.EffectApplicator)

    Supervisor.start_link(children, strategy: :one_for_one, name: Current.Supervisor)
  end
end
