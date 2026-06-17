defmodule TragarAi.Accounts.Token do
  @moduledoc """
  Generation and hashing of gateway secrets.

  We never persist raw API keys or activation tokens — only their SHA-256
  hashes. Lookups hash the presented value and compare against the stored hash,
  so a database leak does not expose usable keys.
  """

  @api_key_prefix "tgr_"

  @doc "A new opaque API key, prefixed `tgr_` for recognisability."
  def generate_api_key, do: @api_key_prefix <> random()

  @doc "A new opaque activation (magic-link) token."
  def generate_activation_token, do: random()

  @doc "Lower-case hex SHA-256 of a secret, for storage and comparison."
  def hash(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
