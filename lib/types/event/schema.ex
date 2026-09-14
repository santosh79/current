defmodule Current.Event.Schema do
  @moduledoc """
  Migrates a raw on-disk event term to the struct shape the running code
  expects. See `Current.Event.Versioned`.
  """

  alias Current.Event

  defmodule UpcastError do
    defexception [:module, :from, :to]

    def message(%{module: m, from: f, to: t}),
      do: "#{inspect(m)} has no upcast from schema version #{f} (current: #{t})"
  end

  defmodule FutureVersionError do
    defexception [:module, :found, :supported]

    def message(%{module: m, found: f, supported: s}),
      do:
        "#{inspect(m)} was written at schema version #{f} but this code only " <>
          "understands up to #{s} -- the WAL was written by newer code"
  end

  # Events written before versioning existed carry no :version key. Their
  # shape is, by definition, version 1.
  @pre_versioning 1

  @spec upcast(term()) :: Event.t()
  def upcast(%{__struct__: mod} = raw) do
    if Event.valid?(raw) do
      migrate(mod, raw)
    else
      raise ArgumentError, "not a known event: #{inspect(mod)}"
    end
  end

  @doc false
  @spec migrate(module(), map()) :: struct()
  def migrate(mod, raw) when is_atom(mod) and is_map(raw) do
    target = mod.schema_version()
    from = Map.get(raw, :version, @pre_versioning)

    raw
    |> Map.delete(:__struct__)
    |> step(mod, from, target)
    |> Map.put(:version, target)
    |> then(&struct(mod, &1))
  end

  defp step(fields, _mod, v, v), do: fields

  defp step(fields, mod, from, to) when from < to,
    do: step(mod.upcast(fields, from), mod, from + 1, to)

  defp step(_fields, mod, from, to) when from > to,
    do: raise(FutureVersionError, module: mod, found: from, supported: to)
end
