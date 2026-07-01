defmodule TragarAi.Freight.AccountsTest do
  use TragarAi.DataCase, async: false

  alias TragarAi.Freight.Accounts

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()
    :persistent_term.erase({Accounts, :directory})
    :ok
  end

  defp stub_accounts(refs) do
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/system/baseData/accounts") ->
          accounts =
            for r <- refs,
                do: %{"accountReference" => r, "name" => "ACME #{r}", "currentStatus" => "ACT"}

          Req.Test.json(conn, %{"response" => %{"esAccounts" => %{"Accounts" => accounts}}})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)
  end

  test "valid? accepts an allocated account and rejects an unknown one" do
    stub_accounts(["ITD02", "ITD03"])

    assert Accounts.valid?("ITD02")
    # case/whitespace-insensitive
    assert Accounts.valid?(" itd02 ")
    refute Accounts.valid?("ITD001")
    refute Accounts.valid?("")
    refute Accounts.valid?(nil)
  end

  test "lookup returns the account map or :error" do
    stub_accounts(["ITD02"])

    assert {:ok, %{"account_reference" => "ITD02"}} = Accounts.lookup("itd02")
    assert :error = Accounts.lookup("NOPE")
  end

  defp stub_account_maps(maps) do
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/system/baseData/accounts") ->
          Req.Test.json(conn, %{"response" => %{"esAccounts" => %{"Accounts" => maps}}})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)
  end

  test "resolve/1 by code, company name, and email domain (with disambiguation)" do
    stub_account_maps([
      %{
        "accountReference" => "ITD02",
        "name" => "INTERNATIONAL TAP DISTRIBUTERS",
        "eMailAddress" => "sales@itdtaps.co.za"
      },
      %{
        "accountReference" => "ITD03",
        "name" => "INTERNATIONAL TAP DISTRIBUTERS",
        "eMailAddress" => "ops@itdtaps.co.za"
      },
      %{
        "accountReference" => "ATL001",
        "name" => "ATLAS FURNITURE",
        "shortName" => "ATLAS",
        "eMailAddress" => "info@atlas.co.za"
      }
    ])

    # explicit valid code wins
    assert Accounts.resolve(%{code: "itd02"}) == {:ok, "ITD02"}
    # unknown code, no other signal → none
    assert Accounts.resolve(%{code: "ITD001"}) == :none
    # unique company name → ok
    assert Accounts.resolve(%{company: "atlas"}) == {:ok, "ATL001"}
    # unique domain → ok
    assert Accounts.resolve(%{domain: "atlas.co.za"}) == {:ok, "ATL001"}
    # company/domain matching several → ambiguous (sorted)
    assert Accounts.resolve(%{company: "international tap"}) == {:ambiguous, ["ITD02", "ITD03"]}
    assert Accounts.resolve(%{domain: "itdtaps.co.za"}) == {:ambiguous, ["ITD02", "ITD03"]}
    # nothing → none
    assert Accounts.resolve(%{}) == :none
  end

  test "fails open (allows) when the directory can't be loaded" do
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      if String.ends_with?(conn.request_path, "/system/auth/login") do
        conn
        |> Plug.Conn.put_resp_header("x-freightware", "tok")
        |> Req.Test.json(%{"response" => %{}})
      else
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)

    # Directory unavailable → don't block legitimate work.
    assert Accounts.valid?("ANYTHING")
  end
end
