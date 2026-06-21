defmodule TragarAiWeb.ConsoleLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{
            "response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}
          })

        String.contains?(conn.request_path, "/waybills/4821") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [%{"waybillNumber" => "4821", "statusDescription" => "In transit"}]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    :ok
  end

  test "renders the console", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/console")
    assert html =~ "Support Assist"
  end

  test "asking drafts an answer the agent can relay", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    html =
      view |> form("form[phx-submit=ask]", %{question: "Where is load 4821?"}) |> render_submit()

    assert html =~ "In transit"
    assert html =~ "FreightWare"

    # Query mode shows details only; reveal the reply box (customer-email use case).
    view |> element("button", "Draft customer reply") |> render_click()

    html =
      view
      |> form("form[phx-submit=relay]", %{final_answer: "It is in transit."})
      |> render_submit()

    assert html =~ "relayed"
  end

  test "a general query resolves the customer name to an account (demo)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    html =
      view
      |> form("form[phx-submit=ask]", %{question: "Does Acme have an open invoice?", demo: "true"})
      |> render_submit()

    assert html =~ "INV-55012"
    assert html =~ "Outstanding"
  end

  test "customer lookup by invoice number resolves the account (demo)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    html =
      view
      |> form("form[phx-submit=ask]", %{
        question: "Who is the customer on INV-55012?",
        demo: "true"
      })
      |> render_submit()

    assert html =~ "Acme Distributors"
  end

  test "a clarifying chat resolves the intent across turns", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    # Turn 1: invoice intent but no account → the AI asks back.
    html =
      view
      |> form("form[phx-submit=ask]", %{question: "Is there an invoice?", demo: "true"})
      |> render_submit()

    assert html =~ "account number"

    # Turn 2: supply the account → the carried intent now resolves.
    html =
      view
      |> form("form[phx-submit=ask]", %{question: "ACC1001", demo: "true"})
      |> render_submit()

    assert html =~ "INV-55012"
  end

  test "selecting a ticket and drafting a reply enters reply mode", %{conn: conn} do
    TragarAi.Demo.seed()
    {:ok, view, _html} = live(conn, ~p"/console")

    view |> element(~s|button[phx-value-id="55"]|) |> render_click()
    html = view |> element("button", "Draft reply") |> render_click()

    # Reply mode shows the relay form for the customer email.
    assert html =~ "Relay to customer"
  end
end
