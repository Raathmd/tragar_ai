defmodule TragarAiWeb.Plugs.IpAllowlistTest do
  use TragarAiWeb.ConnCase, async: false

  alias TragarAiWeb.Plugs.IpAllowlist

  defp conn_from(ip, headers \\ []) do
    conn = %{Phoenix.ConnTest.build_conn() | remote_ip: ip}
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:tragar_ai, :api_allowed_ips)
      Application.delete_env(:tragar_ai, :api_trust_forwarded)
    end)
  end

  test "unset allowlist allows any IP (dev)" do
    refute IpAllowlist.call(conn_from({8, 8, 8, 8}), []).halted
  end

  test "allows an IP inside an allowed CIDR, blocks one outside" do
    Application.put_env(:tragar_ai, :api_allowed_ips, ["10.0.0.0/8", "203.0.113.5/32"])

    refute IpAllowlist.call(conn_from({10, 1, 2, 3}), []).halted
    refute IpAllowlist.call(conn_from({203, 0, 113, 5}), []).halted

    blocked = IpAllowlist.call(conn_from({8, 8, 8, 8}), [])
    assert blocked.halted
    assert blocked.status == 403
  end

  test "with proxy trust, uses the right-most X-Forwarded-For entry" do
    Application.put_env(:tragar_ai, :api_allowed_ips, ["10.0.0.0/8"])
    Application.put_env(:tragar_ai, :api_trust_forwarded, true)

    # Client spoofs a left entry; the trusted proxy appends the real 10.x on the right.
    conn = conn_from({172, 16, 0, 1}, [{"x-forwarded-for", "8.8.8.8, 10.9.9.9"}])
    refute IpAllowlist.call(conn, []).halted

    # Real upstream outside the range → blocked, despite a spoofed left entry.
    conn2 = conn_from({172, 16, 0, 1}, [{"x-forwarded-for", "10.1.1.1, 8.8.8.8"}])
    assert IpAllowlist.call(conn2, []).halted
  end
end
