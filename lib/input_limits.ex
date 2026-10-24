defmodule Current.InputLimits do
  @moduledoc """
  Upper bounds on the free-form input a client can hand the runtime.

  Everything here ends up somewhere that is expensive to take back: the
  prompt and feedback are recorded on events in the append-only WAL (which
  `Current.Consensus.Log` holds in memory and replays on every start) and
  are rendered into every model call; the model name is echoed into error
  responses and the console; the project directory is handed to the
  filesystem. Checking size first, before anything is looked up, recorded
  or logged, keeps an oversized request from ever becoming part of the
  permanent record.

  Sizes are bytes. Binaries are measured with `byte_size/1`, because bytes
  are what the WAL and the provider see. Anything else (a map given as a
  task input, review metadata) is measured with `:erlang.external_size/1`,
  the size of its Erlang external-term encoding. That is a cheap, stable
  *upper-bound proxy*, not the size of the canonical encoding Current
  hashes with or of the JSON a provider receives; use it to bound, not to
  predict.

  Timeouts are not here: `Current.submit_task/3` already bounds them (an
  integer from 1 second to 1 hour).

  ## Configuration

      config :current, input_limits: [prompt: 65_536]

  Keys not listed keep their default. Limits must be positive integers.
  """

  @defaults [
    prompt: 32_768,
    feedback: 16_384,
    message: 4_096,
    reviewed_by: 256,
    model: 256,
    dir: 4_096,
    # The whole metadata map of a review decision, whatever its keys.
    metadata: 8_192
  ]

  @fields Keyword.keys(@defaults)

  @type field :: :prompt | :feedback | :message | :reviewed_by | :model | :dir | :metadata

  @type error :: {:too_large, field(), size :: non_neg_integer(), max :: pos_integer()}

  @doc "The limit for `field`, in bytes."
  @spec max(field()) :: pos_integer()
  def max(field) when field in @fields do
    :current
    |> Application.get_env(:input_limits, [])
    |> Keyword.get(field, Keyword.fetch!(@defaults, field))
  end

  @doc """
  `:ok` if `value` fits `field`'s limit. nil is always fine (whether a
  value is required is some other check's concern). A non-string, such as
  a task input given as a map, is measured by its encoded size.
  """
  @spec check(field(), term()) :: :ok | {:error, error()}
  def check(_field, nil), do: :ok

  def check(field, value) do
    max = __MODULE__.max(field)

    case size(value) do
      size when size <= max -> :ok
      size -> {:error, {:too_large, field, size, max}}
    end
  end

  @doc "`check/2` for a keyword list, stopping at the first field that is too large."
  @spec check_all([{field(), term()}]) :: :ok | {:error, error()}
  def check_all(fields) when is_list(fields) do
    Enum.reduce_while(fields, :ok, fn {field, value}, :ok ->
      case check(field, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Checks a review decision's metadata, which is recorded verbatim on the
  event. The well-known string fields (`:message`, `:reviewed_by`,
  `:feedback`) are checked one by one, so the error names the offender;
  the map as a whole is then held to the `:metadata` limit, so an
  oversized value under any *other* key (or many small keys) can't reach
  the log either.
  """
  @spec check_metadata(map()) :: :ok | {:error, error()}
  def check_metadata(metadata) when is_map(metadata) do
    check_all(
      message: Map.get(metadata, :message),
      reviewed_by: Map.get(metadata, :reviewed_by),
      feedback: Map.get(metadata, :feedback),
      metadata: metadata
    )
  end

  defp size(value) when is_binary(value), do: byte_size(value)
  defp size(value), do: :erlang.external_size(value)
end
