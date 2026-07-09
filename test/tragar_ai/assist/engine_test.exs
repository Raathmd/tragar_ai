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

        # Waybill SEARCH (the shipper-reference fallback) → resolves to 4821.
        String.ends_with?(conn.request_path, "/waybills/") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{"waybillNumber" => "4821", "shipperReference" => "REF123"}
                ]
              }
            }
          })

        # allocated-accounts directory (for account validation/resolution)
        String.contains?(conn.request_path, "/system/baseData/accounts") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esAccounts" => %{
                "Accounts" => [
                  %{"accountReference" => "ITD02", "name" => "INTERNATIONAL TAP DISTRIBUTERS"}
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    # The broad reference probe also hits Vantage (route). Stub it to return no
    # trips so route resolves as not-found rather than erroring.
    Req.Test.stub(TragarAi.Vantage.Client, fn conn ->
      if String.ends_with?(conn.request_path, "/api/auth/login") do
        Req.Test.json(conn, %{"auth_token" => "vt"})
      else
        Req.Test.json(conn, %{"items" => [], "hasNext" => false})
      end
    end)

    # Warm the FreightWare token from the test process so the concurrent gather
    # tasks reuse the cached token instead of logging in from a spawned process
    # (which can't see the Req.Test stub).
    {:ok, _} = TragarAi.Dovetail.TokenStore.token()

    :persistent_term.erase({TragarAi.Freight.Accounts, :directory})
    :ok
  end

  test "an unresolvable account is asked about softly, not hard-rejected" do
    {:ok, i} = Engine.answer("check the invoice for ITD001", %{entities: %{account: "ITD001"}})

    assert i.status == :failed
    assert i.error == "account_needed"
    assert i.draft_answer =~ "account code"
    refute i.draft_answer =~ "isn't a recognised"
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

  test "a new waybill in the prompt overrides the carried one (no stale answer)" do
    # Prior conversation carried waybill 0000; this turn names 4821 — the fresh
    # waybill must win, otherwise the follow-up re-answers the first one.
    assert {:ok, i} = Engine.answer("where is load 4821?", %{entities: %{waybill: "0000"}})
    assert i.status == :drafted
    assert i.facts["waybill_number"] == "4821"
    assert i.draft_answer =~ "4821"
  end

  test "a not-yet-connected source fails safe with a usable message" do
    # Granite (WMS / stock) is still a stub; Vantage (route) is now wired.
    assert {:ok, i} = Engine.answer("what stock is on hand?")
    assert i.status == :failed
    assert i.error == "not_available"
    assert i.draft_answer =~ "Granite"
  end

  test "a delivery-price request drafts a quick quote instead of asking for a quote number" do
    assert {:ok, i} = Engine.answer("How much would it cost to ship a TV to Rendo's Audio?")

    assert i.status == :drafted
    assert i.intent == "quick_quote"
    assert i.source == "FreightWare"
    assert i.draft_answer =~ "quick quote"
    # It names what the guided flow still needs.
    assert i.draft_answer =~ "service"
    refute i.draft_answer =~ "quote number"
  end

  test "an uninterpretable question fails safe" do
    assert {:ok, i} = Engine.answer("hello there")
    assert i.status == :failed
    assert i.error == "not_understood"
  end

  test "a shipper reference resolves to the waybill via account-scoped search" do
    # REF123 isn't a waybill/quote number, but it is the customer's shipper
    # reference — the account-scoped search resolves it to waybill 4821.
    assert {:ok, i} =
             Engine.answer("where is my shipment", %{
               accounts: ["ITD02"],
               entities: %{account: "ITD02", waybill: "REF123"}
             })

    assert i.status == :drafted
    assert i.facts["waybill_number"] == "4821"
  end

  test "an unscoped identifier is flagged, nudging for the account to search on" do
    assert {:ok, i} = Engine.answer("where is 0000?")
    assert i.status == :failed
    assert i.error =~ "unscoped_reference"
    assert i.draft_answer =~ "couldn't match"
    # A bare value may be the customer's own reference — prompt for the account
    # that would let the shipperReference search run.
    assert i.draft_answer =~ "account"
  end

  test "a multi-account request cycles the entitled accounts until the reference resolves" do
    # REF123 isn't a waybill/quote number. The requester is entitled to several
    # accounts — search each in turn (bounded to the entitled set) and surface the
    # first that owns the shipper reference, rather than refusing and asking.
    assert {:ok, i} =
             Engine.answer("where is my shipment", %{
               accounts: ["ITD02", "ABC01"],
               entities: %{waybill: "REF123"}
             })

    assert i.status == :drafted
    assert i.facts["waybill_number"] == "4821"
  end

  test "a requester with no assigned account is never allowed a reference search" do
    # `accounts: []` means the Freshdesk requester has no linked account. A bare
    # reference must NOT be searched — by waybill number OR shipper reference — so
    # we can never surface another account's data to an unentitled requester.
    assert {:ok, i} =
             Engine.answer("where is my shipment", %{
               accounts: [],
               entities: %{waybill: "REF123"}
             })

    assert i.status == :failed
    assert i.error =~ "unscoped_reference"
  end

  test "a shipper reference matching several waybills surfaces them all" do
    # The account-scoped search returns two waybills for REF123 — both are fetched
    # in full and surfaced, not just the first.
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{"response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}})

        String.contains?(conn.request_path, "/waybills/4821/") ->
          Req.Test.json(conn, waybill_json("4821", "In transit"))

        String.contains?(conn.request_path, "/waybills/4822/") ->
          Req.Test.json(conn, waybill_json("4822", "Delivered"))

        # The shipperReference SEARCH returns two matches.
        String.ends_with?(conn.request_path, "/waybills/") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{"waybillNumber" => "4821", "shipperReference" => "REF123"},
                  %{"waybillNumber" => "4822", "shipperReference" => "REF123"}
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    Req.Test.stub(TragarAi.Vantage.Client, fn conn ->
      if String.ends_with?(conn.request_path, "/api/auth/login"),
        do: Req.Test.json(conn, %{"auth_token" => "vt"}),
        else: Req.Test.json(conn, %{"items" => [], "hasNext" => false})
    end)

    assert {:ok, i} =
             Engine.answer("where is my shipment", %{
               accounts: ["ITD02"],
               entities: %{account: "ITD02", waybill: "REF123"}
             })

    assert i.status == :drafted
    numbers = Enum.map(i.facts["results"], & &1["facts"]["waybill_number"])
    assert "4821" in numbers
    assert "4822" in numbers
  end

  test "relay marks the interaction relayed (engine returns an in-memory record)" do
    {:ok, i} = Engine.answer("Where is load 4821?")

    # The engine's return is the live, in-memory record (a plain map) carrying the
    # turn's transient PII fields; relay reloads the slim row by id and updates it.
    assert i.facts["status"] == "In transit"
    assert {:ok, relayed} = Assist.relay_interaction(i, %{agent: "thandi"})
    assert relayed.status == :relayed
    assert relayed.agent == "thandi"
  end

  test "facts and tool_log are not persisted (ephemeral) — only the slim row is" do
    {:ok, i} = Engine.answer("Where is load 4821?")

    # The returned record carries the heavy fields for the turn...
    assert i.facts != %{}
    assert i.tool_log != []

    # ...but the persisted row has no such columns (PII not at rest).
    {:ok, stored} = Assist.get_interaction(i.id)
    refute Map.has_key?(stored, :facts)
    refute Map.has_key?(stored, :tool_log)
    assert stored.question =~ "4821"
    assert stored.status == :drafted
  end

  # A single-waybill detail response (as FreightWare's get_waybill returns it).
  defp waybill_json(number, status) do
    %{
      "response" => %{
        "esWaybills" => %{
          "Waybills" => [
            %{
              "waybillNumber" => number,
              "statusDescription" => status,
              "consigneeName" => "Acme"
            }
          ]
        }
      }
    }
  end
end
