defmodule Current.FaultyEffectApplicator do
  @behaviour Current.EffectApplicator

  alias Current.Intent

  @impl true
  def apply(%Intent{payload: %{force_failure: true}} = intent) do
    unless Mix.env() == :test do
      raise "FaultyEffectApplicator must only be used in test environment"
    end

    {:error, "forced effect failure for intent #{intent.id}"}
  end

  def apply(%Intent{} = intent) do
    unless Mix.env() == :test do
      raise "FaultyEffectApplicator must only be used in test environment"
    end

    Current.EffectApplicator.apply(intent)
  end
end
