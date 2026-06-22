defmodule TragarAi.FreshdeskTest do
  use TragarAi.DataCase, async: true

  alias TragarAi.Freshdesk

  defmodule FakeClient do
    # Records notes posted back so the test can assert on them.
    def start, do: Agent.start_link(fn -> [] end)

    def get_ticket(_id),
      do: {:ok, %{"id" => 1, "custom_fields" => %{"cf_account" => "ITD02"}}}

    def add_note(_ticket_id, attrs) do
      if pid = Process.get(:notes), do: Agent.update(pid, &[attrs | &1])
      {:ok, %{"id" => 99}}
    end

    def create_ticket(attrs), do: {:ok, Map.put(attrs, :id, 555)}

    defmodule FreightWare do
      def create_quote(_), do: {:ok, %{"quote_number" => "Q42"}}
    end
  end

  defmodule NoAccountClient do
    def get_ticket(_id), do: {:ok, %{"id" => 2, "custom_fields" => %{}}}
    def add_note(_, _), do: {:ok, %{}}
  end

  test "account_for/1 reads the account custom field" do
    assert Freshdesk.account_for(%{"custom_fields" => %{"cf_account" => "ITD02"}}) == "ITD02"
    assert Freshdesk.account_for(%{"company_name" => "ACME"}) == "ACME"
    assert Freshdesk.account_for(%{"custom_fields" => %{}}) == nil
  end

  test "run_quote derives the account, runs the flow, and posts the reply back" do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    Process.put(:notes, pid)
    tid = "FD-#{System.unique_integer([:positive])}"

    {:ok, r} = Freshdesk.run_quote(tid, "I need a quote", client: FakeClient)

    assert r.account == "ITD02"
    assert r.reply =~ "service"
    # The reply was posted to the ticket as a private note.
    assert [%{body: body, private: true}] = Agent.get(pid, & &1)
    assert body =~ "service"
  end

  test "run_quote errors when no account is on the ticket" do
    assert {:error, :account_not_found_on_ticket} =
             Freshdesk.run_quote("FD-x", "hi", client: NoAccountClient)
  end

  test "create_test_ticket builds a tagged test ticket" do
    assert {:ok, ticket} =
             Freshdesk.create_test_ticket(%{email: "buyer@acme.co.za"}, client: FakeClient)

    assert ticket.email == "buyer@acme.co.za"
    assert "tragar-test" in ticket.tags
  end
end
