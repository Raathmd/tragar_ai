defmodule TragarAi.Assist.TicketResponderTest do
  use TragarAi.DataCase, async: false

  alias TragarAi.Assist.TicketResponder

  # A fake Freshdesk client that records its calls back to the test process
  # (respond/3 runs synchronously here, so these run in the test process).
  defmodule FakeClient do
    def update_ticket(id, attrs), do: record({:update_ticket, id, attrs})
    def add_note(id, attrs), do: record({:add_note, id, attrs})

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

    TragarAi.DataCase.warm_engine_sources()
    :ok
  end

  test "unchecks the trigger flag first, answers, and pre-fills fields" do
    assert {:ok, result} =
             TicketResponder.respond("55", "Where is load 4821?",
               client: FakeClient,
               account: "ITD02"
             )

    assert result.answer =~ "In transit"
    assert result.account == "ITD02"
    assert result.filled_fields["cf_waybill_number"] == "4821"

    # The trigger checkbox is cleared (unchecked) — the loop-breaker.
    assert_received {:update_ticket, "55", %{custom_fields: %{"cf_tragar_ai" => false}}}
    # The answer is posted back as a private note.
    assert_received {:add_note, "55", %{private: true}}
  end

  test "the flag field name is overridable" do
    assert {:ok, _} =
             TicketResponder.respond("55", "Where is load 4821?",
               client: FakeClient,
               account: "ITD02",
               flag_field: "cf_custom_flag"
             )

    assert_received {:update_ticket, "55", %{custom_fields: %{"cf_custom_flag" => false}}}
  end
end
