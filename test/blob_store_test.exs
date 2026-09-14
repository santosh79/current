defmodule Current.BlobStoreTest do
  use ExUnit.Case, async: false

  alias Current.BlobStore

  test "put/read round trip preserves contents" do
    contents = "artifact store round trip"

    assert {:ok, id} = BlobStore.put(contents)
    assert {:ok, ^contents} = BlobStore.read(id)
  end

  test "same contents produce the same artifact id" do
    contents = "same contents"

    assert {:ok, first_id} = BlobStore.put(contents)
    assert {:ok, second_id} = BlobStore.put(contents)

    assert first_id == second_id
  end

  test "different contents produce different artifact ids" do
    assert {:ok, first_id} = BlobStore.put("first")
    assert {:ok, second_id} = BlobStore.put("second")

    refute first_id == second_id
  end

  test "unknown artifact id returns not_found" do
    unknown = "sha256:" <> String.duplicate("f", 64)

    assert {:error, :not_found} = BlobStore.read(unknown)
    assert {:error, :not_found} = BlobStore.path_for(unknown)
  end
end
