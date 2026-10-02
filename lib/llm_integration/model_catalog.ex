defmodule Current.ModelCatalog do
  @moduledoc """
  Lists models from the configured LLM providers once at application startup
  and stores provider-qualified names in ETS.

  Entries have this form:

      "openai:gpt-5.6"
      "anthropic:claude-opus-5-5"
  """

  use GenServer

  @table __MODULE__
  @timeout_ms 10_000

  @type model_name :: String.t()
  @type provider :: String.t()

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec all() :: [model_name()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {model_name} -> model_name end)
    |> Enum.sort()
  end

  @spec available?(model_name()) :: boolean()
  def available?(model_name) when is_binary(model_name) do
    :ets.member(@table, model_name)
  end

  @doc """
  Splits a catalog entry into its provider and the provider-native model
  ID: `"openai:gpt-5.6"` is `{:ok, "openai", "gpt-5.6"}`.

  Only the first `:` separates the two, so a model ID that itself
  contains one is kept whole.
  """
  @spec split(model_name()) :: {:ok, provider(), Current.LLMClient.model_id()} | :error
  def split(model_name) when is_binary(model_name) do
    case String.split(model_name, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {:ok, provider, model_id}

      _ ->
        :error
    end
  end

  @doc """
  The LLM client module for a catalog entry's provider: the same module
  whose `provider/0` put that prefix on the entry in the first place.

  This only maps the provider to its client. Whether the model itself is
  listed is `available?/1`.
  """
  @spec client_for(model_name()) :: {:ok, module()} | :error
  def client_for(model_name) when is_binary(model_name) do
    with {:ok, provider, _model_id} <- split(model_name),
         client when not is_nil(client) <-
           Enum.find(llm_clients(), &(&1.provider() == provider)) do
      {:ok, client}
    else
      _ -> :error
    end
  end

  @doc """
  Asynchronously re-queries configured providers and replaces the catalog.
  """
  @spec refresh() :: :ok
  def refresh do
    send(__MODULE__, :refresh)
    :ok
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    send(self(), :refresh)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    :ok = refresh_table()
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp refresh_table do
    models = build_mapping()

    case length(models) do
      0 ->
        :ok

      _ ->
        true = :ets.delete_all_objects(@table)
        true = :ets.insert(@table, Enum.map(models, &{&1}))
    end

    :ok
  end

  defp build_mapping() do
    llm_clients()
    |> Enum.flat_map(&models_for_client/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp models_for_client(client) do
    case client.list_models(@timeout_ms) do
      {:ok, models} ->
        provider = client.provider()

        Enum.map(models, fn model ->
          "#{provider}:#{model}"
        end)

      {:error, _reason} ->
        []
    end
  catch
    # The client now runs in this process, so one that raises must not
    # take the catalog down with it: it just contributes no models.
    _kind, _reason -> []
  end

  defp llm_clients do
    Application.get_env(:current, :model_catalog_clients, [
      Current.LLMClient.OpenAI,
      Current.LLMClient.Anthropic
    ])
  end
end
