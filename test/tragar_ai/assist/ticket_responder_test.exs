defmodule TragarAi.Assist.TicketResponderTest do
  use TragarAi.DataCase, async: false

  import TragarAi.FreightWareStub

  alias TragarAi.Assist.TicketResponder

  # A fake Freshdesk client that records its calls back to the test process
  # (respond/3 runs synchronously here, so these run in the test process).
  defmodule FakeClient do
    def update_ticket(id, attrs), do: record({:update_ticket, id, attrs})
    def add_note(id, attrs), do: record({:add_note, id, attrs})

    # A chosen attachment's bytes — a CSV whose only reference is waybill DIS0124440.
    def download("https://files/loads.csv"), do: {:ok, "waybill,status\nDIS0124440,in transit\n"}
    def download(_), do: {:error, :not_found}

    def list_ticket_fields do
      {:ok,
       [
         %{"name" => "cf_waybill_number", "label" => "Waybill number", "type" => "custom_text"},
         %{
           "name" => "cf_waybill_status",
           "label" => "Waybill status",
           "type" => "custom_dropdown",
           "choices" => ["In transit", "Delivered"]
         }
       ]}
    end

    defp record(msg) do
      send(self(), msg)
      {:ok, %{"id" => 1}}
    end
  end

  # Fake Freshdesk facade — supplies the ticket thread as the model's context
  # (avoids hitting the real Freshdesk.Client, which isn't stubbed here).
  defmodule FakeFD do
    def ticket_thread(_id), do: {:ok, %{transcript: "Requestor: Where is load DIS0124440?"}}
  end

  # A thread whose reference can't be resolved (waybill 0000 → not found).
  defmodule UnresolvedFD do
    def ticket_thread(_id), do: {:ok, %{transcript: "Requestor: Where is load 0000?"}}
  end

  # A ticket whose reference lives only in an attachment (not the thread text).
  defmodule AttachmentFD do
    def ticket_thread(_id), do: {:ok, %{transcript: "Requestor: where is my shipment?"}}

    def ticket_attachments(_id) do
      {:ok,
       [
         %{
           id: 1,
           name: "loads.csv",
           content_type: "text/csv",
           size: 30,
           url: "https://files/loads.csv"
         }
       ]}
    end
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

  test "unchecks the trigger flag first, answers, and pre-fills fields" do
    assert {:ok, result} =
             TicketResponder.respond("55", "Where is load DIS0124440?",
               client: FakeClient,
               freshdesk: FakeFD,
               account: "ITD02"
             )

    assert result.answer =~ "In transit"
    assert result.account == "ITD02"
    assert result.filled_fields["cf_waybill_number"] == "DIS0124440"

    # The trigger checkbox is cleared (unchecked) — the loop-breaker.
    assert_received {:update_ticket, "55", %{custom_fields: %{"cf_tragar_ai" => false}}}
    # A resolved answer is posted as a private note labelled as a requestor draft,
    # laid out as HTML so it reads cleanly in Freshdesk.
    assert_received {:add_note, "55", %{body: body, private: true}}
    assert body =~ "Suggested reply to requestor"
    assert body =~ "<strong>"
    assert body =~ "<p>"
  end

  test "an unresolved turn is posted as an agent note (the model needs input)" do
    assert {:ok, _} =
             TicketResponder.respond("55", "ignored",
               client: FakeClient,
               freshdesk: UnresolvedFD,
               account: "ITD02"
             )

    assert_received {:add_note, "55", %{body: body, private: true}}
    assert body =~ "Agent note"
  end

  test "folds a chosen attachment's text into the answer" do
    # The waybill (DIS0124440) appears ONLY in the attachment CSV, not the thread — so a
    # resolved answer proves the extracted text reached the engine.
    assert {:ok, result} =
             TicketResponder.respond("55", "",
               client: FakeClient,
               freshdesk: AttachmentFD,
               account: "ITD02",
               attachment_ids: [1]
             )

    assert result.answer =~ "In transit"
    assert_received {:add_note, "55", %{body: body, private: true}}
    assert body =~ "In transit"
  end

  test "the flag field name is overridable" do
    assert {:ok, _} =
             TicketResponder.respond("55", "Where is load DIS0124440?",
               client: FakeClient,
               freshdesk: FakeFD,
               account: "ITD02",
               flag_field: "cf_custom_flag"
             )

    assert_received {:update_ticket, "55", %{custom_fields: %{"cf_custom_flag" => false}}}
  end
end
