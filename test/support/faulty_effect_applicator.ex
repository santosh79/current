defmodule Current.FaultyEffectApplicator do
  @behaviour Current.EffectApplicator

  alias Current.Intent

  @impl true
  def apply(%Intent{payload: %{force_failure: true}} = intent) do
    __MODULE__.apply(intent, [])
  end

  @impl true
  def apply(%Intent{payload: %{force_failure: true}} = intent, _prior_results) do
    unless Mix.env() == :test do
      raise "FaultyEffectApplicator must only be used in test environment"
    end

    {:error, "forced effect failure for intent #{intent.id}"}
  end

  def apply(%Intent{} = intent, prior_results) do
    unless Mix.env() == :test do
      raise "FaultyEffectApplicator must only be used in test environment"
    end

    Current.EffectApplicator.apply(intent, prior_results)
  end
end
