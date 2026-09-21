defmodule Current.Test.MiniJsonSchema do
  @moduledoc """
  A deliberately narrow JSON Schema validator -- not a general-purpose
  implementation. It supports exactly the keywords
  priv/schema/proposal_response.schema.json uses: type, required,
  properties, items, enum, const, allOf, if/then/else, and $ref (pointing
  only at "#/definitions/<name>", with no sibling keys alongside $ref).

  If the schema file starts using a keyword not listed above, this module
  will silently ignore it rather than validate it -- that's a deliberate
  tradeoff for not pulling in a full JSON Schema library, but it means
  this validator's coverage needs to grow in lockstep with the schema
  file, not be assumed to track it automatically.
  """

  @spec validate(map(), term()) :: :ok | {:error, [String.t()]}
  def validate(root_schema, instance) do
    case do_validate(root_schema, root_schema, instance) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp do_validate(%{"$ref" => ref}, root, instance) do
    do_validate(resolve_ref(ref, root), root, instance)
  end

  defp do_validate(schema, root, instance) when is_map(schema) do
    []
    |> check_type(schema, instance)
    |> check_required(schema, instance)
    |> check_properties(schema, root, instance)
    |> check_items(schema, root, instance)
    |> check_enum(schema, instance)
    |> check_const(schema, instance)
    |> check_all_of(schema, root, instance)
    |> check_if_then_else(schema, root, instance)
  end

  defp resolve_ref("#/definitions/" <> name, root) do
    case get_in(root, ["definitions", name]) do
      nil -> raise "MiniJsonSchema: unresolved $ref: #/definitions/#{name}"
      schema -> schema
    end
  end

  defp check_type(errors, %{"type" => "object"}, instance) when not is_map(instance),
    do: ["expected an object, got: #{inspect(instance)}" | errors]

  defp check_type(errors, %{"type" => "array"}, instance) when not is_list(instance),
    do: ["expected an array, got: #{inspect(instance)}" | errors]

  defp check_type(errors, %{"type" => "string"}, instance) when not is_binary(instance),
    do: ["expected a string, got: #{inspect(instance)}" | errors]

  defp check_type(errors, %{"type" => "number"}, instance) when not is_number(instance),
    do: ["expected a number, got: #{inspect(instance)}" | errors]

  defp check_type(errors, %{"type" => "boolean"}, instance) when not is_boolean(instance),
    do: ["expected a boolean, got: #{inspect(instance)}" | errors]

  defp check_type(errors, _schema, _instance), do: errors

  defp check_required(errors, %{"required" => keys}, instance) when is_map(instance) do
    missing = Enum.filter(keys, &(not Map.has_key?(instance, &1)))

    case missing do
      [] -> errors
      _ -> ["missing required field(s): #{inspect(missing)}" | errors]
    end
  end

  defp check_required(errors, _schema, _instance), do: errors

  defp check_properties(errors, %{"properties" => properties}, root, instance)
       when is_map(instance) do
    Enum.reduce(properties, errors, fn {key, sub_schema}, acc ->
      case Map.fetch(instance, key) do
        {:ok, value} -> acc ++ do_validate(sub_schema, root, value)
        :error -> acc
      end
    end)
  end

  defp check_properties(errors, _schema, _root, _instance), do: errors

  defp check_items(errors, %{"items" => item_schema}, root, instance) when is_list(instance) do
    Enum.reduce(instance, errors, fn item, acc -> acc ++ do_validate(item_schema, root, item) end)
  end

  defp check_items(errors, _schema, _root, _instance), do: errors

  defp check_enum(errors, %{"enum" => allowed}, instance) do
    if instance in allowed,
      do: errors,
      else: ["#{inspect(instance)} is not one of #{inspect(allowed)}" | errors]
  end

  defp check_enum(errors, _schema, _instance), do: errors

  defp check_const(errors, %{"const" => expected}, instance) do
    if instance == expected,
      do: errors,
      else: ["expected constant #{inspect(expected)}, got: #{inspect(instance)}" | errors]
  end

  defp check_const(errors, _schema, _instance), do: errors

  defp check_all_of(errors, %{"allOf" => sub_schemas}, root, instance) do
    Enum.reduce(sub_schemas, errors, fn sub_schema, acc ->
      acc ++ do_validate(sub_schema, root, instance)
    end)
  end

  defp check_all_of(errors, _schema, _root, _instance), do: errors

  defp check_if_then_else(errors, %{"if" => if_schema} = schema, root, instance) do
    branch =
      case do_validate(if_schema, root, instance) do
        [] -> Map.get(schema, "then")
        _ -> Map.get(schema, "else")
      end

    case branch do
      nil -> errors
      branch_schema -> errors ++ do_validate(branch_schema, root, instance)
    end
  end

  defp check_if_then_else(errors, _schema, _root, _instance), do: errors
end
