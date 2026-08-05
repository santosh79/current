defmodule Current.ArtifactStoreTest do
  use ExUnit.Case, async: false

  alias Current.ArtifactStore

  test "put/read round trip preserves contents" do
    contents = "artifact store round trip"

    assert {:ok, id} = ArtifactStore.put(contents)
    assert {:ok, ^contents} = ArtifactStore.read(id)
  end

  test "same contents produce the same artifact id" do
    contents = "same contents"

    assert {:ok, first_id} = ArtifactStore.put(contents)
    assert {:ok, second_id} = ArtifactStore.put(contents)

    assert first_id == second_id
  end

  test "different contents produce different artifact ids" do
    assert {:ok, first_id} = ArtifactStore.put("first")
    assert {:ok, second_id} = ArtifactStore.put("second")

    refute first_id == second_id
  end

  test "unknown artifact id returns not_found" do
    unknown = "sha256:" <> String.duplicate("f", 64)

    assert {:error, :not_found} = ArtifactStore.read(unknown)
    assert {:error, :not_found} = ArtifactStore.path_for(unknown)
  end
end
