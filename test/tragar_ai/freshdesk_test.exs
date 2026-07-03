defmodule TragarAi.FreshdeskTest do
  use TragarAi.DataCase, async: true

  alias TragarAi.Freshdesk

  # A Freshdesk client whose ticket's requester company carries two account codes.
  defmodule FakeClient do
    def get_ticket(_id), do: {:ok, %{"id" => 1, "company_id" => 10}}

    def get_company(10),
      do: {:ok, %{"id" => 10, "custom_fields" => %{"freightware_accounts" => "ITD01, ITD02"}}}

    def add_note(_ticket_id, attrs) do
      if pid = Process.get(:notes), do: Agent.update(pid, &[attrs | &1])
      {:ok, %{"id" => 99}}
    end

    def create_ticket(attrs), do: {:ok, Map.put(attrs, :id, 555)}
  end

  defmodule NoCompanyClient do
    def get_ticket(_id), do: {:ok, %{"id" => 2, "company_id" => nil}}
  end

  defmodule NoAccountClient do
    def get_ticket(_id), do: {:ok, %{"id" => 3, "company_id" => 11}}
    def get_company(11), do: {:ok, %{"id" => 11, "custom_fields" => %{}}}
  end

  # A verifier + FreightWare for the run_quote bridge test.
  defmodule OneAccountFD do
    def accounts_for_requester(_ticket, _opts \\ []), do: {:ok, ["ITD02"]}
  end

  # A client returning a ticket + a mixed conversation (incoming reply, agent
  # note, our own bot note, agent public reply).
  defmodule ThreadClient do
    def get_ticket(_id, _params) do
      {:ok,
       %{
         "id" => 55,
         "subject" => "Where is my parcel",
         "description_text" => "Please find waybill DSV37713735.",
         "requester" => %{"email" => "cust@acme.com"},
         "company" => %{"name" => "Acme"},
         "company_id" => 10
       }}
    end

    def conversations(_id) do
      {:ok,
       [
         c(true, false, "Any update?", "04:00:00"),
         c(false, true, "Checked with ops.", "04:05:00"),
         c(false, true, "Tragar AI\n\nStatus is To Deliver.", "04:06:00"),
         c(false, false, "We're on it.", "04:07:00")
       ]}
    end

    defp c(incoming, private, text, at) do
      %{
        "incoming" => incoming,
        "private" => private,
        "body_text" => text,
        "created_at" => "2026-07-03T#{at}Z"
      }
    end
  end

  describe "accounts_for_requester/2 (the authorization gate)" do
    test "returns the requester company's account code(s), upper-cased + split" do
      assert {:ok, ["ITD01", "ITD02"]} =
               Freshdesk.accounts_for_requester("t1", client: FakeClient)
    end

    test "refuses a requester with no linked company" do
      assert {:error, :requester_not_linked} =
               Freshdesk.accounts_for_requester("t2", client: NoCompanyClient)
    end

    test "refuses when the company carries no account code" do
      assert {:error, :company_has_no_account} =
               Freshdesk.accounts_for_requester("t3", client: NoAccountClient)
    end
  end

  describe "ticket_thread/2 (full context for the model)" do
    test "labels each message Requestor/Agent and excludes our own notes" do
      {:ok, thread} = Freshdesk.ticket_thread("55", client: ThreadClient)
      t = thread.transcript

      assert t =~ "Requestor: Please find waybill DSV37713735."
      assert t =~ "Requestor (reply): Any update?"
      assert t =~ "Agent (note): Checked with ops."
      assert t =~ "Agent (reply): We're on it."
      # Our own bot note is filtered out — the model never reads its own answer.
      refute t =~ "Status is To Deliver."

      assert thread.requester_email == "cust@acme.com"
      assert thread.company_name == "Acme"
    end
  end

  test "run_quote derives the account via Freshdesk and posts the reply back" do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    Process.put(:notes, pid)
    tid = "FD-#{System.unique_integer([:positive])}"

    {:ok, r} =
      Freshdesk.run_quote(tid, "I need a quote", client: FakeClient, freshdesk: OneAccountFD)

    assert r.account == "ITD02"
    assert r.reply =~ "service"
    assert [%{body: body, private: true}] = Agent.get(pid, & &1)
    assert body =~ "service"
  end

  test "create_test_ticket builds a tagged test ticket" do
    assert {:ok, ticket} =
             Freshdesk.create_test_ticket(%{email: "buyer@acme.co.za"}, client: FakeClient)

    assert ticket.email == "buyer@acme.co.za"
    assert "tragar-test" in ticket.tags
  end
end
