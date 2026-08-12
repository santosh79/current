defmodule Current.RuntimeRegistryTest do
  use ExUnit.Case, async: false

  alias Current.{Id, RuntimeRegistry}

  test "put/get round trip preserves the runtime entry" do
    workflow_id = Id.generate()

    entry = %{
      workflow_pid: self(),
      orchestrator_pid: self()
    }

    assert :ok = RuntimeRegistry.put(workflow_id, entry)
    assert {:ok, ^entry} = RuntimeRegistry.get(workflow_id)
  end

  test "put replaces an existing runtime entry" do
    workflow_id = Id.generate()

    first = %{
      workflow_pid: self(),
      orchestrator_pid: self()
    }

    other_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(other_pid), do: Process.exit(other_pid, :kill)
    end)

    second = %{
      workflow_pid: other_pid,
      orchestrator_pid: self()
    }

    assert :ok = RuntimeRegistry.put(workflow_id, first)
    assert :ok = RuntimeRegistry.put(workflow_id, second)
    assert {:ok, ^second} = RuntimeRegistry.get(workflow_id)
  end

  test "delete removes an entry" do
    workflow_id = Id.generate()

    entry = %{
      workflow_pid: self(),
      orchestrator_pid: self()
    }

    assert :ok = RuntimeRegistry.put(workflow_id, entry)
    assert :ok = RuntimeRegistry.delete(workflow_id)
    assert {:error, :not_found} = RuntimeRegistry.get(workflow_id)
  end

  test "get returns not_found for an unknown workflow id" do
    unknown = "sha256:" <> String.duplicate("d", 64)
    assert {:error, :not_found} = RuntimeRegistry.get(unknown)
  end
end
