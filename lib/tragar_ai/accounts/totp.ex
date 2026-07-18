defmodule TragarAi.Accounts.Totp do
  @moduledoc """
  TOTP (RFC 6238) second factor for the margin login. Wraps `NimbleTOTP` for the
  secret, the `otpauth://` provisioning URI, and code verification, plus one-time
  backup recovery codes (shown to the user once, stored only as PBKDF2 hashes).
  The issuer/label shown in the authenticator app is "Tragar Margin".
  """
  alias TragarAi.Accounts.Password

  @issuer "Tragar Margin"

  # Unambiguous alphabet for backup codes (no O/0/I/1/L) — the same lesson as the
  # temp passwords: these codes get read off a screen and typed by a human.
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @backup_count 10
  @backup_len 10

  @doc "A fresh base32 secret (no padding) to store on the user."
  def new_secret, do: Base.encode32(NimbleTOTP.secret(), padding: false)

  @doc "The `otpauth://` URI for the authenticator app (QR + manual entry)."
  def otpauth_uri(email, secret_b32) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", decode(secret_b32), issuer: @issuer)
  end

  @doc "An inline SVG QR code for the given `otpauth://` URI."
  def qr_svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 220)
  end

  @doc "True if `code` is a currently-valid TOTP for the stored secret."
  def valid_code?(secret_b32, code) when is_binary(secret_b32) and is_binary(code) do
    with {:ok, secret} <- Base.decode32(secret_b32, padding: false),
         {:ok, otp} <- normalize_otp(code) do
      NimbleTOTP.valid?(secret, otp)
    else
      _ -> false
    end
  end

  def valid_code?(_secret, _code), do: false

  @doc """
  Generate the one-time backup codes. Returns `{plaintext_codes, hashed_codes}` —
  show the plaintext once, persist only the hashes.
  """
  def generate_backup_codes do
    codes = for _ <- 1..@backup_count, do: random_code()
    {Enum.map(codes, &format/1), Enum.map(codes, &Password.hash/1)}
  end

  @doc "Display form of a raw backup code: FGHJK-MNPQR."
  def format(code) do
    {a, b} = String.split_at(code, div(@backup_len, 2))
    a <> "-" <> b
  end

  @doc """
  Match `input` against the remaining hashed backup codes. On a hit returns
  `{:ok, remaining_hashes}` (the used hash removed); otherwise `:error`.
  """
  def consume_backup_code(hashes, input) when is_list(hashes) and is_binary(input) do
    candidate = input |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")

    case Enum.find(hashes, &Password.verify(candidate, &1)) do
      nil -> :error
      hash -> {:ok, List.delete(hashes, hash)}
    end
  end

  def consume_backup_code(_hashes, _input), do: :error

  defp random_code do
    n = length(@alphabet)

    for <<byte <- :crypto.strong_rand_bytes(@backup_len)>>, into: "" do
      <<Enum.at(@alphabet, rem(byte, n))>>
    end
  end

  defp normalize_otp(code) do
    digits = String.replace(code, ~r/\s/, "")
    if digits =~ ~r/^\d{6}$/, do: {:ok, digits}, else: :error
  end

  defp decode(secret_b32), do: Base.decode32!(secret_b32, padding: false)
end
