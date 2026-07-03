defmodule TragarAi.Adapters.FreightWare.MapperTest do
  use ExUnit.Case, async: true

  alias TragarAi.Adapters.FreightWare.Mapper

  test "shipment surfaces the rated items and charges, not just status" do
    waybill = %{
      "waybill_number" => "DSV37713735",
      "status_description" => "To Deliver",
      "consignor_name" => "Acme",
      "consignee_name" => "Beta",
      "number_of_items" => "1",
      "contents" => "85\" TV",
      "freight_charge" => "450.00",
      "tax_amount" => "67.50",
      "charged_amount" => "517.50",
      "currency_code" => "ZAR",
      "items" => [
        %{
          "quantity" => "1",
          "description" => "85\" TV",
          "total_weight" => "53.4",
          "length" => "209",
          "width" => "21",
          "height" => "128"
        }
      ]
    }

    domain = Mapper.shipment(waybill, [])

    assert domain["waybill_number"] == "DSV37713735"
    assert domain["status"] == "To Deliver"
    # The cost + item detail the model needs to answer "costing"/"quantities".
    assert domain["charged_amount"] == "517.50"
    assert domain["freight_charge"] == "450.00"
    assert domain["number_of_items"] == "1"
    assert domain["contents"] == "85\" TV"
    assert [%{"quantity" => "1", "description" => "85\" TV"}] = domain["items"]
  end

  test "shipment omits blank fields (compact) when the waybill is sparse" do
    domain = Mapper.shipment(%{"waybill_number" => "X1", "status_code" => "DEL"}, [])

    assert domain["waybill_number"] == "X1"
    refute Map.has_key?(domain, "charged_amount")
    refute Map.has_key?(domain, "consignor")
  end
end
