defmodule TragarAi.Assist.TicketChatTest do
  use TragarAi.DataCase, async: false

  import TragarAi.FreightWareStub

  alias TragarAi.Assist.TicketChat

  # Fake Freshdesk facade: entitles the account and exposes one readable CSV
  # attachment whose bytes are served by FakeClient below.
  defmodule FakeFd do
    def accounts_for_requester(_ticket_id), do: {:ok, ["ITD02"]}

    def ticket_attachments(_ticket_id) do
      {:ok,
       [
         %{
           id: 1,
           name: "reference.csv",
           content_type: "text/csv",
           size: 32,
           url: "https://files.example/reference.csv"
         }
       ]}
    end
  end

  defmodule FakeClient do
    # The waybill reference lives ONLY inside the attachment, never in the message.
    def download("https://files.example/reference.csv"), do: {:ok, "waybill\nDIS0124440"}
    def download(_), do: {:error, :not_found}
  end

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
          Req.Test.json(conn, %{"response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}})

        waybill_number?(conn, "DIS0124440") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{"waybillNumber" => "DIS0124440", "statusDescription" => "In transit"}
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    TragarAi.DataCase.warm_engine_sources()
    :ok
  end

  test "auto-extracts a ticket attachment so a reference in a spreadsheet resolves" do
    {:ok, result} =
      TicketChat.answer("55", "Where is my shipment?",
        freshdesk: FakeFd,
        client: FakeClient
      )

    assert result.reply =~ "In transit"
    assert result.accounts == ["ITD02"]
  end
end
