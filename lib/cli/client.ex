defmodule Current.CLI.Client do
  @moduledoc """
  Client-side transport: how the CLI reaches `Current.RPC` on a running
  node. It only ever calls Current.RPC, and turns every transport
  failure into an `{:error, reason}` value instead of an exception.

  The node is `current@localhost` unless `CURRENT_NODE` says otherwise
  (a bare name gets `@localhost`). `bin/current-server` starts the node
  under the same name. Both sides authenticate with the Erlang cookie:
  `~/.erlang.cookie` by default, or `CURRENT_COOKIE`. The CLI joins as a
  hidden node, so it never becomes part of a cluster.

  `local/0` calls Current.RPC in this VM instead, which is what tests use.
  """

  alias Current.Request

  @rpc_timeout_ms 30_000
  @default_host "localhost"

  @enforce_keys [:node, :call]
  defstruct [:node, :call]

  @type t :: %__MODULE__{node: node(), call: (atom(), [term()] -> term())}

  @type error ::
          :runtime_unavailable
          | {:rpc_failed, term()}
          | {:runtime_raised, String.t()}

  ## Connecting

  @doc "Connects to the runtime node."
  @spec connect() :: {:ok, t()} | {:error, :runtime_unavailable}
  def connect do
    target = target_node()

    with :ok <- registered(target),
         :ok <- start_distribution(target),
         :ok <- set_cookie(target),
         true <- Node.connect(target) do
      {:ok,
       %__MODULE__{
         node: target,
         call: fn fun, args -> :erpc.call(target, Current.RPC, fun, args, @rpc_timeout_ms) end
       }}
    else
      {:error, reason} -> {:error, reason}
      _not_connected -> {:error, :runtime_unavailable}
    end
  end

  @doc "A client for Current.RPC in this VM."
  @spec local() :: {:ok, t()}
  def local do
    {:ok, %__MODULE__{node: node(), call: fn fun, args -> apply(Current.RPC, fun, args) end}}
  end

  @spec target_node() :: node()
  def target_node do
    case System.get_env("CURRENT_NODE") do
      value when value in [nil, ""] ->
        :"current@#{@default_host}"

      value ->
        if String.contains?(value, "@"),
          do: String.to_atom(value),
          else: :"#{value}@#{@default_host}"
    end
  end

  ## Current.RPC

  def submit_task(client, %Request{} = request, project_dir),
    do: call(client, :submit_task, [request, project_dir])

  def workflow(client, id), do: call(client, :workflow, [id])
  def proposal(client, id), do: call(client, :proposal, [id])
  def artifact(client, id), do: call(client, :artifact, [id])

  def health(client) do
    case call(client, :health, []) do
      %{status: _} = health -> {:ok, health}
      {:error, _} = error -> error
    end
  end

  defp call(%__MODULE__{call: call}, fun, args) do
    call.(fun, args)
  catch
    :error, {:erpc, :noconnection} ->
      {:error, :runtime_unavailable}

    :error, {:erpc, reason} ->
      {:error, {:rpc_failed, reason}}

    # erpc re-raises a remote exception as {:exception, reason, stack}.
    :error, {:exception, reason, _stack} ->
      {:error, {:runtime_raised, Exception.format_banner(:error, reason)}}
  end

  ## Distribution

  # Asks epmd on the node's host whether the node is registered before
  # starting distribution, so "not running" is a quick, quiet answer
  # rather than net_kernel crash reports.
  defp registered(target) do
    [name, host] = target |> Atom.to_string() |> String.split("@", parts: 2)

    case :erl_epmd.names(String.to_charlist(host)) do
      {:ok, names} ->
        if Enum.any?(names, fn {n, _port} -> to_string(n) == name end),
          do: :ok,
          else: {:error, :runtime_unavailable}

      {:error, _no_epmd} ->
        {:error, :runtime_unavailable}
    end
  end

  defp start_distribution(target) do
    if Node.alive?() do
      :ok
    else
      # Same name domain as the node: a dotted host means --name.
      domain =
        if target |> Atom.to_string() |> String.contains?("."), do: :longnames, else: :shortnames

      host = target |> Atom.to_string() |> String.split("@") |> List.last()
      name = :"current_cli_#{System.pid()}@#{host}"

      case :net_kernel.start(name, %{name_domain: domain, hidden: true}) do
        {:ok, _pid} -> :ok
        # No epmd means no named node is running on this host.
        {:error, _reason} -> {:error, :runtime_unavailable}
      end
    end
  end

  defp set_cookie(target) do
    case System.get_env("CURRENT_COOKIE") do
      value when value in [nil, ""] -> :ok
      cookie -> if Node.set_cookie(target, String.to_atom(cookie)), do: :ok
    end
  end
end
