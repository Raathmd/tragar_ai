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
