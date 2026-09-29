defmodule Current.Excerpt do
  @moduledoc """
  The first part of an artifact, cut to a line budget, for `current review`.

  Runs in the runtime (see Current.Inspector.review/2), so a large artifact
  is cut down before it crosses the wire rather than after.

  An excerpt says exactly what was left out, so a reader (or a script) never
  mistakes a cut artifact for a whole one:

    * `:ok`      -- text, possibly truncated (`truncated: true`): cut to
                    fewer lines, or with over-long lines shortened
                    (`lines_shortened: true`), or both
    * `:binary`  -- not valid UTF-8, or contains NUL; no text
    * `:missing` -- no such blob
    * `:omitted` -- not read: the review's total line budget was spent
  """

  # No single line may blow up a review, however long it is.
  @max_line_bytes 2_000

  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :status,
    :text,
    total_bytes: nil,
    total_lines: nil,
    shown_lines: 0,
    truncated: false,
    lines_shortened: false
  ]

  @type status :: :ok | :binary | :missing | :omitted

  @type t :: %__MODULE__{
          id: Current.Id.t(),
          status: status(),
          text: String.t() | nil,
          total_bytes: non_neg_integer() | nil,
          total_lines: non_neg_integer() | nil,
          shown_lines: non_neg_integer(),
          truncated: boolean(),
          lines_shortened: boolean()
        }

  @doc """
  Cuts `contents` (as returned by BlobStore.read/1) to at most
  `max_lines` lines and at most `budget` lines overall. Returns the
  excerpt and the budget left.
  """
  @spec take(
          Current.Id.t(),
          {:ok, binary()} | {:error, term()},
          pos_integer(),
          non_neg_integer()
        ) :: {t(), non_neg_integer()}
  def take(id, _contents, _max_lines, 0), do: {%__MODULE__{id: id, status: :omitted}, 0}

  def take(id, {:error, _reason}, _max_lines, budget),
    do: {%__MODULE__{id: id, status: :missing}, budget}

  def take(id, {:ok, contents}, max_lines, budget) do
    if String.valid?(contents) and not String.contains?(contents, <<0>>) do
      text(id, contents, min(max_lines, budget), budget)
    else
      {%__MODULE__{id: id, status: :binary, total_bytes: byte_size(contents)}, budget}
    end
  end

  defp text(id, contents, limit, budget) do
    lines = lines(contents)
    total = length(lines)
    {shown, rest} = Enum.split(lines, limit)
    {shown, cut_long?} = shorten_long_lines(shown)

    excerpt = %__MODULE__{
      id: id,
      status: :ok,
      text: Enum.join(shown, "\n"),
      total_bytes: byte_size(contents),
      total_lines: total,
      shown_lines: length(shown),
      truncated: rest != [] or cut_long?,
      lines_shortened: cut_long?
    }

    {excerpt, budget - length(shown)}
  end

  # "a\nb\n" is two lines, not three.
  defp lines(""), do: []

  defp lines(contents) do
    contents
    |> String.trim_trailing("\n")
    |> String.split("\n")
  end

  defp shorten_long_lines(lines) do
    Enum.map_reduce(lines, false, fn line, cut? ->
      if byte_size(line) > @max_line_bytes,
        do: {truncate_utf8(line, @max_line_bytes) <> " …", true},
        else: {line, cut?}
    end)
  end

  # Cuts at a byte limit without splitting a multi-byte character.
  defp truncate_utf8(line, max_bytes) do
    prefix = binary_part(line, 0, max_bytes)

    if String.valid?(prefix),
      do: prefix,
      else: truncate_utf8(line, max_bytes - 1)
  end
end
