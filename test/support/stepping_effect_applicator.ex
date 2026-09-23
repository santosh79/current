defmodule Current.SteppingEffectApplicator do
  @moduledoc """
  A test-only EffectApplicator that pauses before each intent, waiting for
  the controlling test process to explicitly send it a :step message.

  This turns "intent N has applied but intent N+1 hasn't started" from a
  wall-clock race into something a test can drive by hand: send :step,
  wait for confirmation that intent N's EffectApplied went durable, and
  the applicator is guaranteed to still be blocked before intent N+1 even
  begins -- there is a real, controllable window to crash the log inside.

  The controller is discovered by registered name rather than passed as
  an argument, because this callback runs inside the process the
  orchestrator spawns for effect application (see
  Current.WorkflowOrchestrator.start_effect_application/1) -- there's no
  channel to thread state into a @behaviour callback other than something
  process-global like this.
  """

  import Kernel, except: [apply: 3]
  @behaviour Current.EffectApplicator

  @controller_name :stepping_effect_applicator_controller

  @spec controller_name() :: atom()
  def controller_name, do: @controller_name

  @impl true
  def apply(intent, prior_results, project_dir) do
    controller = Process.whereis(@controller_name)

    case controller do
      nil ->
        raise "Current.SteppingEffectApplicator: no process registered as " <>
                "#{inspect(@controller_name)} -- the test must call " <>
                "Process.register(self(), Current.SteppingEffectApplicator.controller_name())"

      _ ->
        :ok
    end

    send(controller, {:awaiting_step, self(), intent})

    receive do
      :step -> :ok
    end

    Current.EffectApplicator.apply(intent, prior_results, project_dir)
  end
end
