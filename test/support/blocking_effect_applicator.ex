defmodule Current.BlockingEffectApplicator do
  import Kernel, except: [apply: 3]
  @behaviour Current.EffectApplicator
  @impl true
  def apply(_intent, _prior_results, _project_dir), do: Process.sleep(:infinity)
end
