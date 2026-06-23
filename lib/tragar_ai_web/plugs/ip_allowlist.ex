defmodule TragarAiWeb.Plugs.IpAllowlist do
  @moduledoc """
  Restricts the `/api` surface to a configured set of source IP ranges (CIDRs) —
  e.g. Freshworks' egress ranges. This holds even if the bearer token leaks: a
  request from any other IP is rejected.

  Config (`config/runtime.exs`):

    * `:api_allowed_ips` — list of CIDR strings (IPv4/IPv6). Empty/unset → allow
      all (local dev). Set `TRAGAR_API_ALLOWED_IPS` to a comma-separated list.
    * `:api_client_ip_header` — when behind a tunnel/edge that sets the real
      client IP in a header (e.g. Cloudflare's `CF-Connecting-IP`), set
      `TRAGAR_API_CLIENT_IP_HEADER=cf-connecting-ip`. The edge overwrites this
      header, so the client can't spoof it (as long as the edge is the only path).
    * `:api_trust_forwarded` — alternatively, when behind a plain proxy/LB, set
      `TRAGAR_API_TRUST_XFF=1` to read the **right-most** `X-Forwarded-For` entry
      (the hop your trusted proxy appended).

  With neither set we use the socket peer (`remote_ip`) — correct when directly
  exposed, so a client can't spoof a header.
  """

  import Plug.Conn
  import Bitwise

  def init(opts), do: opts

  def call(conn, _opts) do
    case allowed_cidrs() do
      [] -> conn
      cidrs -> if allowed?(client_ip(conn), cidrs), do: conn, else: deny(conn)
    end
  end

  defp allowed?(nil, _cidrs), do: false
  defp allowed?(ip, cidrs), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  # ── client IP ─────────────────────────────────────────────────────────────────

  defp client_ip(conn) do
    cond do
      header = Application.get_env(:tragar_ai, :api_client_ip_header) ->
        header_ip(conn, header) || conn.remote_ip

      Application.get_env(:tragar_ai, :api_trust_forwarded, false) ->
        header_ip(conn, "x-forwarded-for") || conn.remote_ip

      true ->
        conn.remote_ip
    end
  end

  # Take the right-most entry (the hop the trusted edge/proxy set). For
  # single-value headers like CF-Connecting-IP this is just the value.
  defp header_ip(conn, header) do
    case get_req_header(conn, String.downcase(header)) do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim() |> parse_ip()
      _ -> nil
    end
  end

  defp parse_ip(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, tuple} -> tuple
      _ -> nil
    end
  end

  # ── CIDR matching ─────────────────────────────────────────────────────────────

  defp allowed_cidrs do
    :tragar_ai
    |> Application.get_env(:api_allowed_ips, [])
    |> List.wrap()
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_cidr(str) when is_binary(str) do
    {addr, prefix} =
      case String.split(str, "/", parts: 2) do
        [a, p] -> {String.trim(a), String.to_integer(p)}
        [a] -> {String.trim(a), nil}
      end

    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, tuple} -> {tuple, prefix || full_prefix(tuple)}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_cidr(_), do: nil

  defp in_cidr?(ip, {net, prefix}) when tuple_size(ip) == tuple_size(net) do
    width = full_prefix(ip)
    shift = width - prefix
    bsr(to_int(ip), shift) == bsr(to_int(net), shift)
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp full_prefix(tuple), do: tuple_size(tuple) * group_bits(tuple)
  defp group_bits(tuple), do: if(tuple_size(tuple) == 4, do: 8, else: 16)

  defp to_int(tuple) do
    bits = group_bits(tuple)
    tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> bsl(acc, bits) + part end)
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    |> halt()
  end
end
