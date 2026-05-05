defmodule Current.ArtifactStore do
  alias Current.Id

  @base_dir Application.compile_env(:current, :artifact_store_dir, "/tmp/current/artifacts")

  @spec put(binary(), binary()) :: {:ok, Id.t()} | {:error, term()}
  def put(name, contents) when is_binary(name) and is_binary(contents) do
    id = Id.generate()
    path = path_for!(id, name)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents) do
      {:ok, id}
    end
  end

  @spec path_for(Id.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def path_for(id) when is_binary(id) do
    case Path.wildcard(Path.join(@base_dir, safe_id(id) <> ".*")) do
      [path | _] -> {:ok, path}
      [] -> {:error, :not_found}
    end
  end

  @spec read(Id.t()) :: {:ok, binary()} | {:error, term()}
  def read(id) when is_binary(id) do
    with {:ok, path} <- path_for(id) do
      File.read(path)
    end
  end

  defp path_for!(id, name) do
    ext = Path.extname(name)

    filename =
      if ext == "" do
        safe_id(id) <> ".artifact"
      else
        safe_id(id) <> ext
      end

    Path.join(@base_dir, filename)
  end

  defp safe_id("sha256:" <> hex), do: "sha256-" <> hex
  defp safe_id(id), do: id |> String.replace(":", "-")
end
