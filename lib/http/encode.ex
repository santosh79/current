defmodule Current.HTTP.Encode do
  @moduledoc """
  Turns the plain data returned by `Current.RPC` into something
  `JSON.encode!/1` accepts.

  The rules are mechanical, so every endpoint is encoded the same way:

    * a struct becomes a map of its fields, plus `"type"`: the last part of
      the module name (`Current.Event.TaskCreated` -> `"TaskCreated"`,
      `Current.Intent.FilePatch` -> `"FilePatch"`);
    * an atom becomes a string (`nil`, `true` and `false` stay as they are);
    * a tuple becomes a list (`{intent, result}` -> `[intent, result]`);
    * a `DateTime` becomes an ISO 8601 string;
    * a binary that isn't valid UTF-8, a pid, a function, or anything else
      JSON has no form for becomes its `inspect/1` string.

  `review` is the exception: it already has a versioned schema
  (`current.review/v1`, see `Current.CLI.ReviewJSON`) and is served as that.
  """

  @spec to_json(term()) :: term()
  def to_json(nil), do: nil
  def to_json(value) when is_boolean(value), do: value
  def to_json(value) when is_atom(value), do: Atom.to_string(value)
  def to_json(value) when is_number(value), do: value

  def to_json(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  def to_json(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def to_json(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> to_json()
    |> Map.put("type", module |> Module.split() |> List.last())
  end

  def to_json(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {key(k), to_json(v)} end)

  def to_json(value) when is_tuple(value), do: value |> Tuple.to_list() |> to_json()

  def to_json(value) when is_list(value) do
    if List.improper?(value), do: inspect(value), else: Enum.map(value, &to_json/1)
  end

  def to_json(value), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
