import Config

case config_env() do
  :prod ->
    config :current, data_dir: System.get_env("CURRENT_DATA_DIR", "./_data")

    case System.get_env("CURRENT_ALLOWED_COMMANDS", nil) do
      nil ->
        :ok

      allowed_commands ->
        aac =
          allowed_commands
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(fn ss ->
            String.length(ss) > 0
          end)

        config :current, allowed_commands: aac
    end

  _ ->
    :ok
end
