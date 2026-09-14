defmodule Current.BlobStore do
  alias Current.Id

  @base_dir Application.compile_env(:current, :blob_store_dir, "/tmp/current/artifacts")

  @spec put(binary()) :: {:ok, Id.t()} | {:error, term()}
  def put(contents) when is_binary(contents) do
    hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    id = "sha256:" <> hash
    path = Path.join(@base_dir, "sha256-" <> hash)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    {:ok, id}
  end

  @spec path_for(Id.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def path_for(id) when is_binary(id) do
    path = Path.join(@base_dir, safe_id(id))

    case File.exists?(path) do
      true -> {:ok, path}
      _ -> {:error, :not_found}
    end
  end

  @spec read(Id.t()) :: {:ok, binary()} | {:error, term()}
  def read(id) when is_binary(id) do
    with {:ok, path} <- path_for(id) do
      File.read(path)
    end
  end

  defp safe_id("sha256:" <> hex), do: "sha256-" <> hex
  defp safe_id(id), do: id |> String.replace(":", "-")
end
