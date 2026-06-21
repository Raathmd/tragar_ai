defmodule TragarAi.Assist.EngineTest do
  use TragarAi.DataCase, async: false

  alias TragarAi.Assist
  alias TragarAi.Assist.Engine

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
            "response" => %{
              "esTrackAndTrace" => %{
                "TrackAndTrace" => [
                  %{"eventDescription" => "Departed JHB", "eventDate" => "2026-06-18"}
                ]
              }
            }
          })

        # empty waybill list = not found
        String.contains?(conn.request_path, "/waybills/0000") ->
          Req.Test.json(conn, %{"response" => %{"esWaybills" => %{"Waybills" => []}}})

        String.contains?(conn.request_path, "/waybills/4821") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{
                    "waybillNumber" => "4821",
                    "statusDescription" => "In transit",
                    "consigneeName" => "Acme"
                  }
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    :ok
  end

  test "answers a live FreightWare status question and drafts an answer" do
    assert {:ok, i} = Engine.answer("Where is load 4821?")
    assert i.status == :drafted
    assert i.intent == "load_status"
    assert i.source == "FreightWare"
    assert i.facts["status"] == "In transit"
    assert i.draft_answer =~ "4821"
    assert i.draft_answer =~ "In transit"
  end

  test "agent-supplied waybill is used when the question omits it" do
    assert {:ok, i} = Engine.answer("where is my delivery?", %{entities: %{waybill: "4821"}})
    assert i.status == :drafted
    assert i.facts["waybill_number"] == "4821"
  end

  test "a not-yet-connected source fails safe with a usable message" do
    assert {:ok, i} = Engine.answer("what is the planned route for 4821?")
    assert i.status == :failed
    assert i.error == "not_available"
    assert i.draft_answer =~ "Vantage"
  end

  test "an uninterpretable question fails safe" do
    assert {:ok, i} = Engine.answer("hello there")
    assert i.status == :failed
    assert i.error == "not_understood"
  end

  test "an unknown waybill fails safe as not_found with an AI prompt-back" do
    assert {:ok, i} = Engine.answer("where is 0000?")
    assert i.status == :failed
    assert i.error == "not_found"
    assert i.draft_answer =~ "couldn't find that reference in Tragar"
  end

  test "relay marks the interaction relayed" do
    {:ok, i} = Engine.answer("Where is load 4821?")

    assert {:ok, relayed} =
             Assist.relay_interaction(i, %{final_answer: "Your load is in transit."})

    assert relayed.status == :relayed
    assert relayed.final_answer == "Your load is in transit."
  end
end
