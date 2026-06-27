defmodule TragarAiWeb.SSLExclude do
  @moduledoc """
  Decides which requests skip the `force_ssl` HTTPS redirect.

  The prod endpoint advertises the Tailscale host over HTTPS, so `force_ssl`
  301-redirects to `https://<PHX_HOST>/`. That's correct for tailnet/public
  traffic, but it breaks office users on the same LAN who reach the box over
  plain HTTP by its `.local` mDNS name or private IP (they can't resolve the
  Tailscale name). This callback excludes those LAN/private hosts so they are
  served directly over HTTP, while everything else still upgrades to HTTPS.

  Wired in via `force_ssl: [exclude: [conn: {__MODULE__, :lan?, []}]]`; Plug.SSL
  prepends the `Plug.Conn` to the args, and a `true` return skips the redirect.
  """

  @doc "True when the request host is loopback, an `*.local` mDNS name, or a private IPv4."
  def lan?(%Plug.Conn{host: host}) when is_binary(host) do
    host in ["localhost", "127.0.0.1"] or
      String.ends_with?(host, ".local") or
      private_ip?(host)
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
end
