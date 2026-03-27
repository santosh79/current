defmodule Current.Id do
  @type t :: String.t()
  @sha256_prefix "sha256:"
  @sha256_hex_length 64

  @spec generate() :: t()
  def generate() do
    "sha256:" <>
      (:crypto.strong_rand_bytes(32)
       |> Base.encode16(case: :lower))
  end

  def validate(@sha256_prefix <> hex) when byte_size(hex) == @sha256_hex_length do
    true = String.match?(hex, ~r/\A[0-9a-f]+\z/)
    :ok
  end
end
