defmodule Current.BlockingEffectApplicator do
  import Kernel, except: [apply: 2]
  @behaviour Current.EffectApplicator
  @impl true
  def apply(_intent, _prior_results), do: Process.sleep(:infinity)
end
