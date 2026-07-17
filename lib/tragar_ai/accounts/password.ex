defmodule TragarAi.Accounts.Password do
  @moduledoc """
  Password hashing with PBKDF2-HMAC-SHA512 via Erlang's built-in `:crypto` — no
  external dependency (avoids a bcrypt NIF and a mix.lock round-trip). Stores a
  self-describing string: `pbkdf2-sha512$<iterations>$<salt b64>$<hash b64>`.
  """
  @iterations 120_000
  @length 32
  @digest :sha512

  @spec hash(String.t()) :: String.t()
  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(@digest, password, salt, @iterations, @length)
    "pbkdf2-sha512$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(hash)}"
  end

  @spec verify(String.t(), String.t() | nil) :: boolean()
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    with ["pbkdf2-sha512", iter, salt64, hash64] <- String.split(stored, "$"),
         {iterations, ""} <- Integer.parse(iter),
         {:ok, salt} <- Base.decode64(salt64),
         {:ok, expected} <- Base.decode64(hash64) do
      actual = :crypto.pbkdf2_hmac(@digest, password, salt, iterations, byte_size(expected))
      Plug.Crypto.secure_compare(actual, expected)
    else
      _ -> false
    end
  end

  def verify(_password, _stored), do: false

  @doc "Burn comparable CPU when the account doesn't exist, to blunt timing/enumeration."
  @spec no_user_verify() :: false
  def no_user_verify do
    :crypto.pbkdf2_hmac(@digest, "no-user", <<0::128>>, @iterations, @length)
    false
  end
end
