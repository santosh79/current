defmodule Current.BlobStore do
  alias Current.Id

  @spec put(binary()) :: {:ok, Id.t()} | {:error, term()}
  def put(contents) when is_binary(contents) do
    hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    id = "sha256:" <> hash
    path = Path.join(base_dir(), "sha256-" <> hash)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    {:ok, id}
  end

  @spec path_for(Id.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def path_for(id) when is_binary(id) do
    path = Path.join(base_dir(), safe_id(id))

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

  @doc """
  Ids of stored blobs starting with `prefix` (e.g. "sha256:6c8e06"), so
  a shortened id can be resolved. Only lowercase hex is accepted after
  "sha256:", which also keeps the prefix from being read as a glob.
  """
  @spec ids_with_prefix(String.t()) :: [Id.t()]
  def ids_with_prefix("sha256:" <> hex) do
    if String.match?(hex, ~r/\A[0-9a-f]*\z/) do
      base_dir()
      |> Path.join("sha256-" <> hex <> "*")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        "sha256:" <> String.replace_prefix(Path.basename(path), "sha256-", "")
      end)
    else
      []
    end
  end

  def ids_with_prefix(_prefix), do: []

  defp safe_id("sha256:" <> hex), do: "sha256-" <> hex
  defp safe_id(id), do: id |> String.replace(":", "-")

  defp base_dir do
    :current
    |> Application.fetch_env!(:data_dir)
    |> Path.expand()
    |> Path.join("artifacts")
  end
end
