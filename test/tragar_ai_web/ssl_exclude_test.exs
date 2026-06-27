defmodule TragarAiWeb.SSLExcludeTest do
  use ExUnit.Case, async: true

  alias TragarAiWeb.SSLExclude

  defp conn(host), do: %Plug.Conn{host: host}

  test "LAN hosts are excluded from the HTTPS redirect" do
    for host <- ~w(localhost 127.0.0.1 studio.local 192.168.1.10 10.0.0.5 172.16.0.1 172.31.255.1) do
      assert SSLExclude.lan?(conn(host)), "#{host} should be LAN"
    end
  end

  test "Tailscale hosts (100.64.0.0/10 and *.ts.net) are excluded" do
    for host <- ~w(100.64.0.1 100.100.20.30 100.127.255.254 studio.tailnet-name.ts.net) do
      assert SSLExclude.lan?(conn(host)), "#{host} should be tailnet"
    end
  end

  test "public hosts and 100.x outside the CGNAT band still upgrade to HTTPS" do
    for host <- ~w(example.com 100.63.0.1 100.128.0.1 8.8.8.8 172.15.0.1 172.32.0.1) do
      refute SSLExclude.lan?(conn(host)), "#{host} should NOT be excluded"
    end
  end

  test "a non-Plug.Conn arg is never excluded" do
    refute SSLExclude.lan?(%{not: :a_conn})
  end
end
