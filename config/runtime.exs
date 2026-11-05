import Config

if config_env() == :prod do
  config :current, data_dir: System.get_env("CURRENT_DATA_DIR", "./_data")
end

# CURRENT_ALLOWED_COMMANDS overrides allowed_commands in every environment.
# When unset, the value from config/*.exs is preserved.
# An explicitly empty value disables all commands.

case System.get_env("CURRENT_ALLOWED_COMMANDS") do
  nil ->
    :ok

  value ->
    commands =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :current, allowed_commands: commands
end
