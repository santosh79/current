defmodule Current.EventNotifier do
  @moduledoc """
  In-memory notification routing for canonical EventStore entries.

  EventStore remains responsible only for validating and projecting
  canonical events. This module owns subscription routing.

  Notifications are best-effort latency hints. Consumers requiring
  correctness must be able to catch up from EventStore.
  """

  alias Current.Event
  alias Current.EventStore.Entry

  @registry Current.EventRegistry

  @type subscribe_error ::
          :invalid_event_type
          | :subscriber_must_be_self

  # SantoshTODO: Refactor this into it's own type
  @event_types MapSet.new([
                 :task_created,
                 :workflow_created,
                 :proposal_production_started,
                 :mode_invalid,
                 :proposal_produced,
                 :proposal_validated,
                 :proposal_validation_failed,
                 :proposal_production_failed,
                 :proposal_approved,
                 :proposal_rejected,
                 :effect_application_started,
                 :effect_applied,
                 :effect_failed,
                 :effect_application_complete,
                 :workflow_result_assembled,
                 :workflow_completed,
                 :workflow_failed,
                 :workflow_abandoned
               ])

  @spec subscribe(pid(), atom()) ::
          :ok | {:error, subscribe_error()}
  def subscribe(pid, event_type) when is_pid(pid) do
    cond do
      pid != self() ->
        {:error, :subscriber_must_be_self}

      event_type == :all or MapSet.member?(@event_types, event_type) ->
        register(event_type)

      true ->
        {:error, :invalid_event_type}
    end
  end

  @spec subscribe(pid(), Current.Id.t(), atom()) ::
          :ok | {:error, subscribe_error()}
  def subscribe(pid, workflow_id, event_type)
      when is_pid(pid) and is_binary(workflow_id) do
    cond do
      pid != self() ->
        {:error, :subscriber_must_be_self}

      event_type == :all or MapSet.member?(@event_types, event_type) ->
        register({:workflow, workflow_id, event_type})

      true ->
        {:error, :invalid_event_type}
    end
  end

  @spec notify(Entry.t()) :: :ok
  def notify(%Entry{event: event} = entry) do
    event
    |> subscription_keys()
    |> subscribers_for_keys()
    |> Enum.each(fn pid ->
      send(pid, {:event_committed, entry})
    end)

    :ok
  end

  defp register(key) do
    case Registry.register(@registry, key, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        :ok
    end
  end

  defp subscription_keys(event) do
    type = event_type(event)

    global = [
      :all,
      type
    ]

    case Map.get(event, :workflow_id) do
      nil ->
        global

      workflow_id ->
        [
          {:workflow, workflow_id, :all},
          {:workflow, workflow_id, type}
          | global
        ]
    end
  end

  defp subscribers_for_keys(keys) do
    Enum.reduce(keys, MapSet.new(), fn key, acc ->
      @registry
      |> Registry.lookup(key)
      |> Enum.reduce(acc, fn {pid, _value}, acc ->
        MapSet.put(acc, pid)
      end)
    end)
  end

  defp event_type(%Event.TaskCreated{}), do: :task_created
  defp event_type(%Event.WorkflowCreated{}), do: :workflow_created
  defp event_type(%Event.ProposalProductionStarted{}), do: :proposal_production_started
  defp event_type(%Event.ModeInvalid{}), do: :mode_invalid
  defp event_type(%Event.ProposalProduced{}), do: :proposal_produced
  defp event_type(%Event.ProposalValidated{}), do: :proposal_validated
  defp event_type(%Event.ProposalValidationFailed{}), do: :proposal_validation_failed
  defp event_type(%Event.ProposalProductionFailed{}), do: :proposal_production_failed
  defp event_type(%Event.ProposalApproved{}), do: :proposal_approved
  defp event_type(%Event.ProposalRejected{}), do: :proposal_rejected
  defp event_type(%Event.EffectApplicationStarted{}), do: :effect_application_started
  defp event_type(%Event.EffectApplied{}), do: :effect_applied
  defp event_type(%Event.EffectFailed{}), do: :effect_failed
  defp event_type(%Event.EffectApplicationComplete{}), do: :effect_application_complete
  defp event_type(%Event.WorkflowResultAssembled{}), do: :workflow_result_assembled
  defp event_type(%Event.WorkflowCompleted{}), do: :workflow_completed
  defp event_type(%Event.WorkflowFailed{}), do: :workflow_failed
  defp event_type(%Event.WorkflowAbandoned{}), do: :workflow_abandoned
end
