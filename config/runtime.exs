import Config

# Tests keep their explicit dependency-injection and temporary-directory
# overrides, regardless of environment variables inherited by `mix test`.
if config_env() != :test do
  {:ok, _} = Application.ensure_all_started(:yaml_elixir)

  explicit_path =
    case System.get_env("CURRENT_CONFIG") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end

  path = explicit_path || "current.yaml"

  config :current,
         Current.ConfigLoader.load(path, System.get_env(), required: not is_nil(explicit_path))
end
