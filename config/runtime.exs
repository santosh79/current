import Config

if config_env() == :prod do
  config :current, data_dir: System.get_env("CURRENT_DATA_DIR", "./_data")
end
