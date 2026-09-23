defmodule Current.Event.SchemaTest do
  use ExUnit.Case, async: true

  alias Current.{Event, Id}
  alias Current.Event.Schema

  # A stand-in with real migration history: v1 had `name`, v2 renamed it to
  # `title`, v3 added `priority` with a default.
  defmodule Ticket do
    use Current.Event.Versioned, version: 3
    defstruct [:id, :title, priority: :normal, version: @schema_version]

    def upcast(fields, 1), do: fields |> Map.put(:title, fields.name) |> Map.delete(:name)
    def upcast(fields, 2), do: fields
  end

  defmodule Additive do
    use Current.Event.Versioned, version: 2
    defstruct [:id, new_field: :default, version: @schema_version]

    def upcast(fields, 1), do: fields
  end

  describe "every event module" do
    test "declares a schema version that matches its struct default" do
      Enum.each(Event.modules(), fn mod ->
        {:module, ^mod} = Code.ensure_loaded(mod)

        assert function_exported?(mod, :schema_version, 0),
               "#{inspect(mod)} does not `use Current.Event.Versioned`"

        assert struct(mod).version == mod.schema_version(),
               "#{inspect(mod)}'s defstruct default for :version drifted from its schema_version/0"
      end)
    end
  end

  describe "upcast/1" do
    test "is the identity on a current-version event" do
      event = %Event.WorkflowCompleted{
        id: Id.generate(),
        workflow_id: Id.generate(),
        timestamp: DateTime.utc_now()
      }

      assert Schema.upcast(event) == event
    end

    test "treats a record with no :version key as version 1 and adds the key" do
      event = %Event.WorkflowCompleted{
        id: Id.generate(),
        workflow_id: Id.generate(),
        timestamp: DateTime.utc_now()
      }

      pre_versioning = Map.delete(event, :version)

      assert Schema.upcast(pre_versioning) == event
    end

    test "rejects a term that is not a known event" do
      assert_raise ArgumentError, fn -> Schema.upcast(%{__struct__: Ticket, id: 1}) end
    end
  end

  describe "migrate/2" do
    test "chains upcasts one version at a time" do
      raw = %{__struct__: Ticket, id: 7, name: "old name", version: 1}

      assert %Ticket{id: 7, title: "old name", priority: :normal, version: 3} =
               Schema.migrate(Ticket, raw)
    end

    test "fills newly added fields from struct defaults" do
      raw = %{__struct__: Ticket, id: 7, title: "already renamed", version: 2}
      assert %Ticket{priority: :normal, version: 3} = Schema.migrate(Ticket, raw)
    end

    test "drops fields the current struct no longer has" do
      raw = %{__struct__: Ticket, id: 7, title: "t", legacy_flag: true, version: 3}
      refute Map.has_key?(Schema.migrate(Ticket, raw), :legacy_flag)
    end

    test "raises when the record was written by newer code" do
      raw = %{__struct__: Ticket, id: 7, title: "t", version: 4}
      assert_raise Schema.FutureVersionError, fn -> Schema.migrate(Ticket, raw) end
    end

    test "raises when a required upcast step is missing" do
      defmodule Gap do
        use Current.Event.Versioned, version: 2
        defstruct [:id, version: @schema_version]
      end

      raw = %{__struct__: Gap, id: 1, version: 1}
      assert_raise Schema.UpcastError, fn -> Schema.migrate(Gap, raw) end
    end

    test "a v1 TaskCreated (before project_dir existed) upcasts with project_dir nil, not a guess" do
      now = DateTime.utc_now()

      raw = %{
        __struct__: Event.TaskCreated,
        id: Id.generate(),
        task_id: Id.generate(),
        input: "old task",
        context: %{},
        mode: :plan,
        submitted_at: now,
        timestamp: now,
        version: 1
      }

      assert %Event.TaskCreated{project_dir: nil, version: 2} =
               Schema.migrate(Event.TaskCreated, raw)
    end

    test "a v2 TaskCreated keeps the project_dir it recorded" do
      now = DateTime.utc_now()

      event = %Event.TaskCreated{
        id: Id.generate(),
        task_id: Id.generate(),
        input: "new task",
        context: %{},
        mode: :plan,
        project_dir: "/srv/projects/app",
        submitted_at: now,
        timestamp: now
      }

      assert Schema.upcast(event) == event
    end

    test "an additive version bump still requires an explicit identity upcast" do
      raw = %{__struct__: Additive, id: 123, version: 1}
      assert %Additive{id: 123, new_field: :default, version: 2} = Schema.migrate(Additive, raw)
    end
  end
end
