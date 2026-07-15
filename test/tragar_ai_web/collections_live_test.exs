defmodule TragarAiWeb.CollectionsLiveTest do
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

        String.contains?(conn.request_path, "/collections/unauthorised") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esUnAuthorisedCollections" => %{
                "unAuthorisedCollections" => [
                  %{
                    "collectionReference" => "REF01",
                    "originatingBranch" => "DBN",
                    "collectionDate" => "2026-07-14",
                    "consignorName" => "Joe",
                    "consigneeName" => "Jane",
                    "consigneeCity" => "JNB",
                    "estimatedWaybills" => 2,
                    "estimatedParcels" => 10
                  }
                ]
              },
              "esErrors" => %{}
            }
          })

        String.contains?(conn.request_path, "/collections/outstanding") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esManifestCollections" => %{
                "ManifestCollections" => [
                  %{
                    "collectionReference" => "OUT99",
                    "collectionDate" => "2026-07-13",
                    "routeCode" => "R1",
                    "driverReference" => "D5"
                  },
                  %{
                    "collectionReference" => "WB77",
                    "collectionDate" => "2026-07-12",
                    "waybills" => 3
                  }
                ]
              },
              "esErrors" => %{}
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    {:ok, _} = TragarAi.Dovetail.TokenStore.token()
    :ok
  end

  test "lists unauthorised and outstanding collections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collections")
    html = render_async(view, 5000)

    assert html =~ "Awaiting authorisation"
    assert html =~ "Outstanding"
    assert html =~ "REF01"
    assert html =~ "OUT99"
    # Outstanding shows route/driver.
    assert html =~ "R1"
    # Waybilled collections are hidden by default (waybills filter defaults to 0).
    refute html =~ "WB77"
  end

  test "showing all waybills surfaces already-waybilled collections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collections")
    render_async(view, 5000)

    html =
      view
      |> element("form[phx-change=\"filter\"]")
      |> render_change(%{"filters" => %{"waybills" => ""}})

    assert html =~ "WB77"
  end
end
