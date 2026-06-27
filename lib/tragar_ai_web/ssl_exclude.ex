defmodule TragarAiWeb.SSLExclude do
  @moduledoc """
  Decides which requests skip the `force_ssl` HTTPS redirect.

  The prod endpoint advertises the Tailscale host over HTTPS, so `force_ssl`
  301-redirects to `https://<PHX_HOST>/`. That's correct for public traffic, but
  it breaks internal users who reach the box directly over plain HTTP:

    * office users on the same LAN, by its `.local` mDNS name or private IP, and
    * tailnet users, by the Studio's Tailscale IP (`100.64.0.0/10`) or its
      MagicDNS `*.ts.net` name.

  The tailnet is already end-to-end encrypted, so serving it over HTTP is fine.
  This callback excludes those LAN/tailnet hosts so they are served directly over
  HTTP, while everything else still upgrades to HTTPS.

  Wired in via `force_ssl: [exclude: [conn: {__MODULE__, :lan?, []}]]`; Plug.SSL
  prepends the `Plug.Conn` to the args, and a `true` return skips the redirect.
  """

  @doc """
  True when the request host is loopback, an `*.local` mDNS name, a private IPv4,
  or a Tailscale host (`100.64.0.0/10` IP or `*.ts.net` MagicDNS name).
  """
  def lan?(%Plug.Conn{host: host}) when is_binary(host) do
    host in ["localhost", "127.0.0.1"] or
      String.ends_with?(host, ".local") or
      String.ends_with?(host, ".ts.net") or
      private_ip?(host) or
      tailscale_ip?(host)
  end

  def lan?(_conn), do: false

  defp private_ip?("192.168." <> _), do: true
  defp private_ip?("10." <> _), do: true
  defp private_ip?("127." <> _), do: true

  defp private_ip?("172." <> rest) do
    case Integer.parse(rest) do
      {n, "." <> _} when n in 16..31 -> true
      _ -> false
    end
  end

  defp private_ip?(_), do: false

  # Tailscale's CGNAT range is 100.64.0.0/10 — i.e. 100.64.x.x through
  # 100.127.x.x (second octet 64..127). Note this excludes ordinary public
  # 100.x addresses outside that band.
  defp tailscale_ip?("100." <> rest) do
    case Integer.parse(rest) do
      {n, "." <> _} when n in 64..127 -> true
      _ -> false
    end
  end

  defp tailscale_ip?(_), do: false
end
