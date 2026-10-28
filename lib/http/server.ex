defmodule Current.HTTP.Server do
  @moduledoc """
  Starts the HTTP API (`Current.HTTP.Router`) under Bandit.

  The API does no authentication. Like a Kafka broker, it is meant to sit
  behind whatever you already use to decide who may talk to it: network
  policy, security groups, a reverse proxy or gateway, a tailnet. Because
  `approve` and `apply` write to the project, treat access to the port as
  access to the project.

  Defaults are chosen so that skipping all of that is still reasonable on a
  personal machine: it listens on 127.0.0.1 only. Any other process or user
  on the machine can still call it. If you bind to a non-loopback address,
  a warning is logged.

  Configure the listener under `http` in `current.yaml`, or with
  `CURRENT_HTTP_PORT`, and `CURRENT_HTTP_IP`.

  """

  require Logger

  @doc "Child specs for the supervisor."
  @spec children() :: [Supervisor.child_spec()]
  def children do
    config = Application.get_env(:current, :http, [])
    port = Keyword.get(config, :port, 4000)
    ip = Keyword.get(config, :ip, {127, 0, 0, 1})

    if ip != {127, 0, 0, 1} and ip != {0, 0, 0, 0, 0, 0, 0, 1} do
      Logger.warning(
        "HTTP API is bound to #{:inet.ntoa(ip)}, which does no authentication; " <>
          "restrict access with network rules or a gateway"
      )
    end

    Logger.info("HTTP API listening on #{:inet.ntoa(ip)}:#{port}")
    [{Bandit, plug: Current.HTTP.Router, scheme: :http, ip: ip, port: port}]
  end
end
