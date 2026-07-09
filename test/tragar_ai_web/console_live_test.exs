defmodule TragarAiWeb.ConsoleLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    # FreightWare (Dovetail) — waybill 4821 lookups for the ask/relay flow.
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{"response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}})

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

    # Freshdesk — the left-panel ticket list, agent filter, and ticket fetch.
    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/agents") ->
          Req.Test.json(conn, [%{"id" => 1, "contact" => %{"name" => "Thandi"}}])

        String.ends_with?(conn.request_path, "/tickets/55") ->
          Req.Test.json(conn, %{
            "id" => 55,
            "subject" => "Where is parcel 4821",
            "description_text" => "Customer asks where waybill 4821 is."
          })

        String.ends_with?(conn.request_path, "/tickets") ->
          Req.Test.json(conn, [
            %{"id" => 55, "subject" => "Where is parcel 4821", "status" => 2, "responder_id" => 1}
          ])

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    TragarAi.DataCase.warm_engine_sources()
    :ok
  end

  test "renders the console with the Freshdesk ticket panel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/console")
    assert html =~ "Support Assist"
    assert html =~ "Freshdesk tickets"
    # The open ticket from the stub is listed.
    assert html =~ "Where is parcel 4821"
  end

  test "the console nav links to the dashboard and chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")
    assert view |> element(~s{nav a[href="/"]}) |> has_element?()
    assert view |> element(~s{nav a[href="/chat"]}) |> has_element?()
  end

  test "asking surfaces the fetched facts as a drafted answer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    view |> form("form[phx-submit=ask]", %{question: "Where is load 4821?"}) |> render_submit()
    html = render_async(view, 5000)

    assert html =~ "In transit"
    assert html =~ "FreightWare"
  end

  test "clicking a ticket loads its contents into a pre-filled prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    view |> element(~s|button[phx-value-id="55"]|) |> render_click()
    html = render_async(view, 5000)

    # The ticket's actual contents (subject + body) land in the prompt textarea for
    # the agent to edit and submit — no distillation.
    assert html =~ "Where is parcel 4821"
  end

  test "clicking a ticket offers the requester's entitled accounts from the FD API", %{conn: conn} do
    # The ticket's requester is linked to a Freshdesk company carrying two
    # FreightWare accounts — clicking the ticket checks the FD API (ticket →
    # company → freightware_accounts) and offers those as the account chooser
    # (with "Check all"), rather than a content guess.
    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/tickets/55") ->
          Req.Test.json(conn, %{
            "id" => 55,
            "subject" => "Where is parcel 4821",
            "description_text" => "Customer asks where waybill 4821 is.",
            "company_id" => 900
          })

        String.ends_with?(conn.request_path, "/tickets") ->
          Req.Test.json(conn, [
            %{"id" => 55, "subject" => "Where is parcel 4821", "status" => 2, "responder_id" => 1}
          ])

        String.ends_with?(conn.request_path, "/companies/900") ->
          Req.Test.json(conn, %{
            "id" => 900,
            "custom_fields" => %{"freightware_accounts" => "ITD02, ABC01"}
          })

        String.ends_with?(conn.request_path, "/agents") ->
          Req.Test.json(conn, [%{"id" => 1, "contact" => %{"name" => "Thandi"}}])

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/console")
    view |> element(~s|button[phx-value-id="55"]|) |> render_click()
    html = render_async(view, 5000)

    assert html =~ "ITD02"
    assert html =~ "ABC01"
    assert html =~ "Check all"
  end
end
