defmodule Current.Event.Versioned do
  @moduledoc """
  Declares an event module's schema version and gives it an overridable
  `upcast/2` for migrating older on-disk shapes forward one version at a
  time.

  Events are written to the WAL as raw Erlang terms and read back as
  plain maps tagged with `__struct__`. Adding, removing, or renaming a
  field changes what `%Event.X{}` means without changing what is on
  disk. The rules:

    * Every schema-version bump requires an `upcast(fields, from)` clause
    for the version being left behind. For a purely additive change (a
    new field with a default) that clause just returns `fields`;
    `struct/2` fills the default afterwards.
    * A rename, a removed field, or a field whose meaning changed must be
      handled explicitly in that clause.
    * Never delete an `upcast/2` clause. Old WALs may still need it.
  """

  defmacro __using__(opts) do
    version = Keyword.fetch!(opts, :version)

    quote do
      @schema_version unquote(version)

      @spec schema_version() :: pos_integer()
      def schema_version, do: @schema_version

      @spec upcast(map(), pos_integer()) :: map()
      def upcast(_fields, from) do
        raise Current.Event.Schema.UpcastError,
          module: __MODULE__,
          from: from,
          to: @schema_version
      end

      defoverridable upcast: 2
    end
  end
end
