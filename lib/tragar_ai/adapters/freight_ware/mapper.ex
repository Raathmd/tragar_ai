defmodule TragarAi.Adapters.FreightWare.Mapper do
  @moduledoc """
  Maps FreightWare-normalized data (`TragarAi.Freight.Normalize` output) into
  Tragar's **domain** shape (`Shipment`, `Quote`). Pure functions, shared by the
  adapter and the cache so the source→domain mapping lives in one place.
  """

  @doc "FreightWare waybill + tracking → domain shipment."
  def shipment(waybill, events) when is_map(waybill) do
    %{
      "waybill_number" => waybill["waybill_number"],
      "account_reference" => waybill["account_reference"],
      "status" => waybill["status_description"] || waybill["status_code"],
      "status_code" => waybill["status_code"],
      "service_type" => waybill["service_type_description"] || waybill["service_type"],
      "consignor" => waybill["consignor_name"],
      "consignee" => waybill["consignee_name"],
      "consignee_city" => waybill["consignee_city"],
      # The rated items + charges FreightWare supplies on the waybill, so the model
      # can answer costing / quantities / contents — not just status.
      "contents" => waybill["contents"],
      "number_of_items" => waybill["number_of_items"],
      "items" => waybill["items"] || [],
      "freight_charge" => waybill["freight_charge"],
      "sundry_charge" => waybill["sundry_charge"],
      "tax_amount" => waybill["tax_amount"],
      "charged_amount" => waybill["charged_amount"],
      "consignment_value" => waybill["consignment_value"],
      "currency_code" => waybill["currency_code"],
      "events" => events,
      "pod" => pod_from(events, waybill)
    }
    |> compact()
  end

  @doc "FreightWare quote → domain quote."
  def quote(q) when is_map(q) do
    %{
      "quote_number" => q["quote_number"],
      "quote_obj" => q["quote_obj"],
      "account_reference" => q["account_reference"],
      "status" => q["status_description"] || q["status_code"],
      "status_code" => q["status_code"],
      "service_type" => q["service_type"],
      "consignor" => q["consignor_name"],
      "consignee" => q["consignee_name"],
      "charged_amount" => q["charged_amount"],
      "items" => q["items"] || [],
      "sundries" => q["sundries"] || []
    }
    |> compact()
  end

  defp pod_from(events, waybill) do
    case Enum.find_value(events, & &1["pod"]) do
      pod when is_map(pod) -> pod
      _ -> if waybill["pod_image_url"], do: %{"image_url" => waybill["pod_image_url"]}, else: nil
    end
  end

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
