defmodule Current.ConfigLoader do
  @moduledoc """
  Loads operator settings with this precedence:

      built-in defaults < YAML file < CURRENT_* environment variables

  Dependency-injection modules and provider secrets deliberately remain
  outside this module. Unknown keys and invalid values raise an
  `ArgumentError` that identifies their source.
  """

  @providers ["openai", "anthropic"]

  @settings [
    {[:data_dir], "./_data", :non_empty_string, "CURRENT_DATA_DIR"},
    {[:http, :ip], "127.0.0.1", :ip, "CURRENT_HTTP_IP"},
    {[:http, :port], 4_000, :port, "CURRENT_HTTP_PORT"},
    {[:llm, :call_timeout_ms], 240_000, :positive_integer, "CURRENT_LLM_CALL_TIMEOUT_MS"},
    {[:llm, :task_timeout_ms], 600_000, :positive_integer, "CURRENT_LLM_TASK_TIMEOUT_MS"},
    {[:llm, :providers], @providers, :providers, "CURRENT_LLM_PROVIDERS"},
    {[:llm, :openai, :base_url], nil, :optional_https_url, "CURRENT_OPENAI_BASE_URL"},
    {[:llm, :anthropic, :base_url], nil, :optional_https_url, "CURRENT_ANTHROPIC_BASE_URL"},
    {[:workflow, :max_revisions], 10, :non_negative_integer, "CURRENT_MAX_REVISIONS"},
    {[:workflow, :runner_max_attempts], 5, :positive_integer,
     "CURRENT_WORKFLOW_RUNNER_MAX_ATTEMPTS"},
    {[:workflow, :runner_base_backoff_ms], 1_000, :non_negative_integer,
     "CURRENT_WORKFLOW_RUNNER_BASE_BACKOFF_MS"},
    {[:workflow, :runner_max_backoff_ms], 30_000, :non_negative_integer,
     "CURRENT_WORKFLOW_RUNNER_MAX_BACKOFF_MS"},
    {[:wal, :segment_bytes], 64 * 1024 * 1024, :positive_integer,
     "CURRENT_COMMIT_LOG_SEGMENT_BYTES"},
    {[:input_limits, :prompt], 32_768, :positive_integer, "CURRENT_INPUT_LIMIT_PROMPT"},
    {[:input_limits, :feedback], 16_384, :positive_integer, "CURRENT_INPUT_LIMIT_FEEDBACK"},
    {[:input_limits, :message], 4_096, :positive_integer, "CURRENT_INPUT_LIMIT_MESSAGE"},
    {[:input_limits, :reviewed_by], 256, :positive_integer, "CURRENT_INPUT_LIMIT_REVIEWED_BY"},
    {[:input_limits, :model], 256, :positive_integer, "CURRENT_INPUT_LIMIT_MODEL"},
    {[:input_limits, :dir], 4_096, :positive_integer, "CURRENT_INPUT_LIMIT_DIR"},
    {[:input_limits, :metadata], 8_192, :positive_integer, "CURRENT_INPUT_LIMIT_METADATA"},
    {[:mcp, :allowed_origins], [], :origins, "CURRENT_MCP_ALLOWED_ORIGINS"},
    {[:mcp, :allow_loopback_origins], true, :boolean, "CURRENT_MCP_ALLOW_LOOPBACK_ORIGINS"}
  ]

  @doc "Loads a configuration file and environment map into application config."
  @spec load(Path.t(), map(), keyword()) :: keyword()
  def load(path, env \\ System.get_env(), opts \\ [])
      when is_binary(path) and is_map(env) and is_list(opts) do
    required? = Keyword.get(opts, :required, false)
    defaults = defaults()
    file = load_file(path, required?)
    from_file = normalize!(file, schema(), "configuration file #{path}", [])

    defaults
    |> deep_merge(from_file)
    |> apply_env(env)
    |> validate_relationships!()
    |> to_app_env()
  end

  defp put_schema(schema, [key], type), do: Map.put(schema, key, {:leaf, type})

  defp put_schema(schema, [key | rest], type) do
    Map.update(schema, key, put_schema(%{}, rest, type), &put_schema(&1, rest, type))
  end

  defp defaults do
    Enum.reduce(@settings, %{}, fn {path, default, type, _env}, config ->
      put_path(config, path, parse!(default, type, "built-in default", path))
    end)
  end

  defp load_file(path, required?) do
    cond do
      File.regular?(path) ->
        case YamlElixir.read_from_file(path) do
          {:ok, nil} ->
            %{}

          {:ok, value} ->
            value

          {:error, reason} ->
            raise ArgumentError, "configuration file #{path}: #{inspect(reason)}"
        end

      required? ->
        raise ArgumentError, "configuration file #{path} does not exist"

      true ->
        %{}
    end
  end

  defp normalize!(value, schema, source, path) when is_map(value) and is_map(schema) do
    Enum.reduce(value, %{}, fn {key, child}, result ->
      atom_key = known_key(key, schema)

      if is_nil(atom_key) do
        invalid!(source, path ++ [key], "unknown setting")
      end

      normalized = normalize!(child, Map.fetch!(schema, atom_key), source, path ++ [atom_key])
      Map.put(result, atom_key, normalized)
    end)
  end

  defp normalize!(value, {:leaf, type}, source, path), do: parse!(value, type, source, path)

  defp normalize!(_value, _schema, source, path) do
    invalid!(source, path, "expected a mapping")
  end

  defp known_key(key, schema) when is_binary(key) do
    Enum.find(Map.keys(schema), &(Atom.to_string(&1) == key))
  end

  defp known_key(key, schema) when is_atom(key) do
    if Map.has_key?(schema, key), do: key
  end

  defp known_key(_key, _schema), do: nil

  defp apply_env(config, env) do
    Enum.reduce(@settings, config, fn {path, _default, type, variable}, result ->
      case Map.get(env, variable) do
        value when value in [nil, ""] -> result
        value -> put_path(result, path, parse_env!(value, type, variable, path))
      end
    end)
  end

  defp parse_env!(value, type, source, path) when type in [:providers, :origins] do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> parse!(type, source, path)
  end

  defp parse_env!(value, type, source, path), do: parse!(value, type, source, path)

  defp parse!(value, :non_empty_string, _source, _path)
       when is_binary(value) and value != "",
       do: value

  defp parse!(value, :non_empty_string, source, path),
    do: invalid!(source, path, "expected a non-empty string, got #{inspect(value)}")

  defp parse!(value, :boolean, _source, _path) when is_boolean(value), do: value
  defp parse!("true", :boolean, _source, _path), do: true
  defp parse!("false", :boolean, _source, _path), do: false

  defp parse!(value, :boolean, source, path),
    do: invalid!(source, path, "expected true or false, got #{inspect(value)}")

  defp parse!(value, :positive_integer, _source, _path)
       when is_integer(value) and value > 0,
       do: value

  defp parse!(value, :positive_integer, source, path) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> invalid!(source, path, "expected a positive integer, got #{inspect(value)}")
    end
  end

  defp parse!(value, :positive_integer, source, path),
    do: invalid!(source, path, "expected a positive integer, got #{inspect(value)}")

  defp parse!(value, :non_negative_integer, _source, _path)
       when is_integer(value) and value >= 0,
       do: value

  defp parse!(value, :non_negative_integer, source, path) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> invalid!(source, path, "expected a non-negative integer, got #{inspect(value)}")
    end
  end

  defp parse!(value, :non_negative_integer, source, path),
    do: invalid!(source, path, "expected a non-negative integer, got #{inspect(value)}")

  defp parse!(value, :port, _source, _path)
       when is_integer(value) and value in 1..65_535,
       do: value

  defp parse!(value, :port, source, path) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..65_535 -> integer
      _ -> invalid!(source, path, "expected a port from 1 to 65535, got #{inspect(value)}")
    end
  end

  defp parse!(value, :port, source, path),
    do: invalid!(source, path, "expected a port from 1 to 65535, got #{inspect(value)}")

  defp parse!(value, :ip, source, path) when is_binary(value) do
    case value |> String.to_charlist() |> :inet.parse_address() do
      {:ok, address} -> address
      {:error, _reason} -> invalid!(source, path, "expected an IP address, got #{inspect(value)}")
    end
  end

  defp parse!(value, :ip, source, path),
    do: invalid!(source, path, "expected an IP address, got #{inspect(value)}")

  defp parse!(value, :providers, source, path) when is_list(value) do
    if Enum.all?(value, &(&1 in @providers)) do
      Enum.uniq(value)
    else
      invalid!(source, path, "expected a list containing only #{Enum.join(@providers, ", ")}")
    end
  end

  defp parse!(value, :providers, source, path),
    do: invalid!(source, path, "expected a provider list, got #{inspect(value)}")

  defp parse!(value, :origins, source, path) when is_list(value) do
    if Enum.all?(value, &valid_origin?/1) do
      Enum.uniq(value)
    else
      invalid!(source, path, "expected origins in scheme://host[:port] form")
    end
  end

  defp parse!(value, :origins, source, path),
    do: invalid!(source, path, "expected an origin list, got #{inspect(value)}")

  defp parse!(nil, :optional_https_url, _source, _path), do: nil

  defp parse!(value, :optional_https_url, source, path) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        String.trim_trailing(value, "/")

      _ ->
        invalid!(source, path, "expected an HTTPS URL without credentials, query, or fragment")
    end
  end

  defp parse!(value, :optional_https_url, source, path),
    do:
      invalid!(
        source,
        path,
        "expected an HTTPS URL without credentials, query, or fragment, got #{inspect(value)}"
      )

  defp valid_origin?(origin) when is_binary(origin) do
    case URI.new(origin) do
      {:ok,
       %URI{
         scheme: scheme,
         host: host,
         userinfo: nil,
         query: nil,
         fragment: nil,
         path: path
       }}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  defp valid_origin?(_origin), do: false

  defp validate_relationships!(config) do
    base = get_in(config, [:workflow, :runner_base_backoff_ms])
    maximum = get_in(config, [:workflow, :runner_max_backoff_ms])

    if base <= maximum do
      config
    else
      invalid!(
        "effective configuration",
        [:workflow, :runner_base_backoff_ms],
        "must be less than or equal to workflow.runner_max_backoff_ms"
      )
    end
  end

  defp to_app_env(config) do
    app = [
      data_dir: config.data_dir,
      http: [ip: config.http.ip, port: config.http.port],
      llm_proposal_timeout_ms: config.llm.call_timeout_ms,
      llm_task_timeout_ms: config.llm.task_timeout_ms,
      enabled_providers: config.llm.providers,
      max_revisions: config.workflow.max_revisions,
      workflow_runner_max_attempts: config.workflow.runner_max_attempts,
      workflow_runner_base_backoff_ms: config.workflow.runner_base_backoff_ms,
      workflow_runner_max_backoff_ms: config.workflow.runner_max_backoff_ms,
      commit_log_segment_bytes: config.wal.segment_bytes,
      input_limits: Enum.to_list(config.input_limits),
      mcp: Enum.to_list(config.mcp)
    ]

    app
    |> maybe_put_provider(Current.LLMClient.OpenAI, config.llm.openai.base_url)
    |> maybe_put_provider(Current.LLMClient.Anthropic, config.llm.anthropic.base_url)
  end

  defp maybe_put_provider(config, _provider, nil), do: config

  defp maybe_put_provider(config, provider, base_url),
    do: Keyword.put(config, provider, base_url: base_url)

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    Map.update(map, key, put_path(%{}, rest, value), &put_path(&1, rest, value))
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end

  defp invalid!(source, path, message) do
    key = Enum.map_join(path, ".", &to_string/1)
    raise ArgumentError, "#{source}: invalid #{key}: #{message}"
  end

  defp schema do
    Enum.reduce(@settings, %{}, fn {path, _default, type, _env}, schema ->
      put_schema(schema, path, type)
    end)
  end
end
