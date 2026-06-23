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

  # Pass the fake FreightWare on every turn so site search + rating hit the fake.
  defp step(base, msg),
    do: Server.handle(Map.put(base, :message, msg), freightware: FakeFreightWare)

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
