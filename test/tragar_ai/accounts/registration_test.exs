defmodule TragarAi.Accounts.RegistrationTest do
  use TragarAi.DataCase, async: false

  import Swoosh.TestAssertions

  alias TragarAi.Accounts
  alias TragarAi.Accounts.Registration

  setup do
    {:ok, account} =
      Accounts.upsert_account(%{account_reference: "ACC1", email: "ops@acme.test", name: "Acme"})

    %{account: account}
  end

  describe "request_access/2" do
    test "matching account+email creates a pending client and emails a magic link" do
      assert :ok = Registration.request_access("ACC1", "OPS@Acme.test")

      assert {:ok, clients} = Accounts.list_clients()
      assert [client] = clients
      assert client.status == :pending
      assert client.account_reference == "ACC1"

      assert_email_sent(fn email ->
        assert email.to == [{"", "ops@acme.test"}]
        assert email.text_body =~ "/activate/"
      end)
    end

    test "non-matching email creates nothing and sends no email" do
      assert :ok = Registration.request_access("ACC1", "attacker@evil.test")
      assert {:ok, []} = Accounts.list_clients()
      assert_no_email_sent()
    end

    test "unknown account is a no-op" do
      assert :ok = Registration.request_access("NOPE", "ops@acme.test")
      assert {:ok, []} = Accounts.list_clients()
    end
  end

  describe "activate/1" do
    test "issues a usable key from the magic-link token" do
      :ok = Registration.request_access("ACC1", "ops@acme.test")
      token = sent_activation_token()

      assert {:ok, "tgr_" <> _ = key, client} = Registration.activate(token)
      assert client.status == :active

      assert {:ok, resolved} = Registration.resolve(key)
      assert resolved.id == client.id

      # token is single-use
      assert {:error, :invalid_or_expired} = Registration.activate(token)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_or_expired} = Registration.activate("bogus")
    end
  end

  defp sent_activation_token do
    assert_email_sent(fn email ->
      assert [_, token] = Regex.run(~r{/activate/([^\s"]+)}, email.text_body)
      send(self(), {:token, token})
    end)

    receive do
      {:token, token} -> token
    after
      0 -> flunk("no activation token captured")
    end
  end
end
