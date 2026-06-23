defmodule TragarAi.QuoteIntakeTest do
  use TragarAi.DataCase, async: true

  alias TragarAi.QuoteIntake.{Flow, Server}

  defmodule FakeFreightWare do
    def search_sites(_q),
      do:
        {:ok,
         [
           %{
             "site_code" => "I902",
             "site_name" => "ITALTILE MENLYN",
             "suburb" => "MENLYN",
             "city" => "PRETORIA",
             "post_code" => "0063",
             "account_reference" => "ITD01"
           }
         ]}

    def resolve_service_type(_text), do: {:ok, %{"code" => "ECO", "name" => "ECONOMY"}}
    def quick_quote(_params), do: {:ok, [%{"service_type" => "ECO", "total_charge" => "1234.00"}]}
    def create_quote(_params), do: {:ok, %{"quote_number" => "Q9001"}}
  end

  defmodule MultiSiteFW do
    def search_sites(_q) do
      {:ok,
       [
         %{
           "site_code" => "I902",
           "site_name" => "ITALTILE MENLYN",
           "suburb" => "MENLYN",
           "city" => "PRETORIA",
           "post_code" => "0063",
           "account_reference" => "ITD01"
         },
         %{
           "site_code" => "I916",
           "site_name" => "ITALTILE BOKSBURG",
           "suburb" => "BARDENE",
           "city" => "BOKSBURG",
           "post_code" => "1459",
           "account_reference" => "ITD01"
         },
         %{
           "site_code" => "I905",
           "site_name" => "ITALTILE BRYANSTON",
           "suburb" => "BRYANSTON",
           "city" => "JOHANNESBURG",
           "post_code" => "2191",
           "account_reference" => "ITD01"
         }
       ]}
    end
  end

  defmodule NoPostalFW do
    # A site that comes back without a postal code.
    def search_sites(_q),
      do:
        {:ok,
         [
           %{
             "site_code" => "I902",
             "site_name" => "ITALTILE MENLYN",
             "suburb" => "MENLYN",
             "city" => "PRETORIA",
             "post_code" => "",
             "account_reference" => "ITD01"
           }
         ]}

    def resolve_service_type(_), do: {:ok, %{"code" => "ECO"}}
    def quick_quote(_), do: {:ok, []}
    def create_quote(_), do: {:ok, %{"quote_number" => "Q1"}}
  end

  # Requester verifiers (the account-derivation gate).
  defmodule OneAccountFD do
    def accounts_for_requester(_t, _o \\ []), do: {:ok, ["ITD02"]}
  end

  defmodule MultiAccountFD do
    def accounts_for_requester(_t, _o \\ []), do: {:ok, ["ITD01", "ITD02"]}
  end

  defmodule NoAccountFD do
    def accounts_for_requester(_t, _o \\ []), do: {:error, :requester_not_linked}
  end

  describe "Flow (pure)" do
    test "next_unfilled walks slots in order; address slots need a resolved site" do
      assert Flow.next_unfilled(%{}) == "service"
      assert Flow.next_unfilled(%{"service" => "ECO"}) == "collection"

      # A bare string does not fill an address slot — it needs a resolved site.
      refute Flow.filled?(%{"collection" => "Sandton"}, "collection")
      assert Flow.filled?(%{"collection" => %{"site_code" => "I902"}}, "collection")

      ready = %{
        "service" => "ECO",
        "collection" => %{"site_code" => "I902"},
        "delivery" => %{"site_code" => "I905"},
        "goods" => "x"
      }

      assert Flow.next_unfilled(ready) == nil
      assert Flow.question("collection") =~ "collecting"
    end

    test "to_quote_params maps resolved sites to consignor/consignee fields" do
      slots = %{
        "service" => "Economy",
        "service_code" => "ECO",
        "collection" => %{
          "site_code" => "I902",
          "name" => "ITALTILE MENLYN",
          "suburb" => "MENLYN",
          "post_code" => "0063"
        },
        "delivery" => %{
          "site_code" => "I905",
          "name" => "ITALTILE BRYANSTON",
          "suburb" => "BRYANSTON",
          "post_code" => "2191"
        },
        "goods" => "3 pallets of tiles, 1200kg, 120x100x150"
      }

      params = Flow.to_quote_params(slots, "ITD02")

      assert params["account_reference"] == "ITD02"
      assert params["service_type"] == "ECO"
      assert params["consignor_site"] == "I902"
      assert params["consignor_postal_code"] == "0063"
      assert params["consignee_site"] == "I905"
      assert params["consignee_postal_code"] == "2191"

      assert [
               %{
                 "quantity" => "3",
                 "weight" => "1200",
                 "length" => "120",
                 "width" => "100",
                 "height" => "150"
               }
             ] =
               params["items"]
    end
  end

  # Pass the fakes on every turn so derivation, site search and rating hit fakes.
  defp step(base, msg),
    do:
      Server.handle(Map.put(base, :message, msg),
        freightware: FakeFreightWare,
        freshdesk: OneAccountFD
      )

  describe "Server (guided conversation)" do
    test "search+confirm sites, resolve service code, rate, and create the quote" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      {:ok, r0} = step(base, "I need a quote")
      assert r0.reply =~ "service"
      assert r0.status == "collecting"

      {:ok, _} = step(base, "Economy")

      # Collection: a place name triggers a site search + numbered list.
      {:ok, c1} = step(base, "Italtile Menlyn")
      assert c1.reply =~ "I902"
      # Pick #1 → advances to the delivery question.
      {:ok, c2} = step(base, "1")
      assert c2.reply =~ "delivering"

      {:ok, _} = step(base, "Italtile Bryanston")
      {:ok, g} = step(base, "1")
      assert g.reply =~ "shipping"

      {:ok, ready} = step(base, "3 pallets, 1200kg, 120x100x150")

      assert ready.status == "ready"
      assert ready.reply =~ "ACCEPT"
      assert ready.rate == "1234.00"
      assert ready.quote_params["service_type"] == "ECO"
      assert ready.quote_params["consignor_site"] == "I902"

      {:ok, done} = step(base, "ACCEPT")
      assert done.status == "accepted"
      assert done.quote_number == "Q9001"
      assert done.complete
    end

    test "ranks the closest site first using all the words the user gave" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      run = fn msg ->
        Server.handle(Map.put(base, :message, msg),
          freightware: MultiSiteFW,
          freshdesk: OneAccountFD
        )
      end

      run.("quote")
      run.("Economy")
      {:ok, r} = run.("Italtile Bryanston 2191")

      # I905 matches italtile + bryanston + 2191 → ranked #1 over the other Italtiles.
      assert r.reply =~ "1. I905"
    end

    test "asks for the postal code when the chosen site has none (required to rate)" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      run = fn msg ->
        Server.handle(Map.put(base, :message, msg),
          freightware: NoPostalFW,
          freshdesk: OneAccountFD
        )
      end

      run.("quote")
      run.("Economy")
      run.("Italtile Menlyn")
      {:ok, p} = run.("1")
      assert p.reply =~ "postal code"

      # Supplying it advances to the delivery question.
      {:ok, d} = run.("0063")
      assert d.reply =~ "delivering"
    end

    test "derives the account from Freshdesk; refuses a requester with no account" do
      base = %{ticket_id: "T-#{System.unique_integer([:positive])}"}

      {:ok, r} = Server.handle(Map.put(base, :message, "quote"), freshdesk: NoAccountFD)
      assert r.status == "refused"
      assert r.complete
      assert r.reply =~ "couldn't find a Tragar account"
    end

    test "asks which account when the requester is entitled to several" do
      base = %{ticket_id: "T-#{System.unique_integer([:positive])}"}

      run = fn msg ->
        Server.handle(Map.put(base, :message, msg),
          freightware: FakeFreightWare,
          freshdesk: MultiAccountFD
        )
      end

      {:ok, r0} = run.("quote")
      assert r0.status == "choosing_account"
      assert r0.reply =~ "Which account"
      assert r0.reply =~ "ITD01" and r0.reply =~ "ITD02"

      # Picking #2 selects ITD02 and moves on to the service question.
      {:ok, r1} = run.("2")
      assert r1.reply =~ "service"
    end

    test "REJECT cancels the request" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      step(base, "hi")
      step(base, "Economy")
      step(base, "Italtile Menlyn")
      step(base, "1")
      step(base, "Italtile Bryanston")
      step(base, "1")
      step(base, "1 box, 5kg, 30x20x15")

      {:ok, done} = step(base, "REJECT")
      assert done.status == "rejected"
      assert done.complete
    end
  end
end
