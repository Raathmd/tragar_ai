defmodule TragarAi.Tools.Normalize do
  @moduledoc """
  Translates FreightWare's (camelCase, deeply-nested) payloads into the clean,
  flat, snake_case maps the gateway returns to AI callers.

  FreightWare field names vary across endpoints, so every lookup tolerates
  several candidate keys.
  """

  @doc "Full shipment view: waybill detail + tracking events + POD."
  def shipment(waybill_number, waybill_data, tracking) do
    events = events(tracking)

    waybill(waybill_number, waybill_data)
    |> Map.merge(%{
      "events" => events,
      "last_event" => List.first(events),
      "pod" => pod(tracking, events)
    })
  end

  @doc "Waybill detail without tracking history."
  def waybill(waybill_number, data) when is_map(data) do
    %{
      "waybill_number" => dig(data, ["waybillNumber", "waybill_number"]) || waybill_number,
      "status" =>
        dig(data, ["statusDescription", "status_description"]) ||
          dig(data, ["statusCode", "status_code"]),
      "status_code" => dig(data, ["statusCode", "status_code"]),
      "account_reference" => dig(data, ["accountReference", "account_reference"]),
      "shipper_reference" => dig(data, ["shipperReference", "shipper_reference"]),
      "service_type" => dig(data, ["serviceType", "service_type"]),
      "service_type_description" =>
        dig(data, ["serviceTypeDescription", "service_type_description"]),
      "consignor" => dig(data, ["consignorName", "consignor_name"]),
      "consignor_city" => dig(data, ["consignorCity", "consignor_city"]),
      "consignee" => dig(data, ["consigneeName", "consignee_name"]),
      "consignee_city" => dig(data, ["consigneeCity", "consignee_city"]),
      "number_of_items" => dig(data, ["numberOfItems", "number_of_items"]),
      "waybill_date" => dig(data, ["waybillDate", "waybill_date"])
    }
    |> compact()
  end

  def waybill(waybill_number, _), do: %{"waybill_number" => waybill_number}

  @doc "Normalize a list of tracking events."
  def events(tracking) do
    tracking
    |> extract_events()
    |> Enum.map(fn e ->
      %{
        "code" => dig(e, ["eventCode", "event_code"]),
        "date" => dig(e, ["eventDate", "event_date"]),
        "time" => dig(e, ["eventTime", "event_time"]),
        "description" => dig(e, ["eventDescription", "event_description"]),
        "branch" => dig(e, ["branchCode", "branch_code"])
      }
      |> compact()
    end)
  end

  @doc "Normalize service type base data."
  def service_types(data) do
    data
    |> as_list(["serviceTypes", "service_types"])
    |> Enum.map(fn st ->
      %{
        "code" => dig(st, ["serviceTypeCode", "code"]),
        "name" => dig(st, ["serviceTypeDescription", "name"]),
        "description" => dig(st, ["comment", "serviceTypeShortDesc", "description"])
      }
      |> compact()
    end)
  end

  @doc "Normalize quick-quote rates."
  def rates(data) do
    data
    |> rates_list()
    |> Enum.map(fn r ->
      %{
        "service_type" => dig(r, ["serviceType", "service_type"]),
        "total" => dig(r, ["totalCharge", "total_charge", "rateAmount", "rate_amount"]),
        "freight_charge" => dig(r, ["freightCharge", "freight_charge"]),
        "sundry_charge" => dig(r, ["sundryCharge", "sundry_charge"]),
        "tax" => dig(r, ["taxAmount", "tax_amount"]),
        "estimated_days" => dig(r, ["estimatedDays", "estimated_days"])
      }
      |> compact()
    end)
  end

  @doc """
  Build a FreightWare quick-quote request body from the gateway's flat args.
  Mirrors the shape the Rust reference sent; the Dovetail client wraps it in the
  `request` envelope.
  """
  def quote_request(args) do
    %{
      "accountReference" => args["account_reference"],
      "serviceType" => args["service_type"],
      "consignorPostalCode" => args["collection_postal_code"],
      "consigneePostalCode" => args["delivery_postal_code"],
      "items" =>
        (args["items"] || [])
        |> Enum.map(fn item ->
          %{
            "quantity" => item["quantity"],
            "totalWeight" => item["weight"],
            "length" => item["length"],
            "width" => item["width"],
            "height" => item["height"]
          }
          |> compact()
        end)
    }
    |> compact()
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp extract_events(%{"events" => events}) when is_list(events), do: events
  defp extract_events(%{"trackEvents" => events}) when is_list(events), do: events
  defp extract_events(%{"trackingEvents" => events}) when is_list(events), do: events
  defp extract_events(%{"trackAndTrace" => inner}) when is_map(inner), do: extract_events(inner)
  defp extract_events(events) when is_list(events), do: events
  defp extract_events(_), do: []

  # POD may be attached to the latest delivered event, or sit at the top level.
  defp pod(tracking, events) do
    raw_pod =
      get_in(tracking, ["pod"]) ||
        events |> Enum.find_value(fn e -> e["pod"] end) ||
        nil

    case raw_pod do
      pod when is_map(pod) ->
        %{
          "date" => dig(pod, ["podDate", "pod_date"]),
          "time" => dig(pod, ["podTime", "pod_time"]),
          "receiver" => dig(pod, ["receiverName", "receiver_name"]),
          "parcels" => dig(pod, ["numberOfParcels", "number_of_parcels"]),
          "image_url" => dig(pod, ["podImageUrl", "pod_image_url"]),
          "comments" => dig(pod, ["comments"])
        }
        |> compact()

      _ ->
        nil
    end
  end

  defp rates_list(%{"esRates" => %{"rates" => rates}}) when is_list(rates), do: rates
  defp rates_list(%{"es_rates" => %{"rates" => rates}}) when is_list(rates), do: rates
  defp rates_list(%{"rates" => rates}) when is_list(rates), do: rates
  defp rates_list(rates) when is_list(rates), do: rates
  defp rates_list(_), do: []

  defp as_list(data, _keys) when is_list(data), do: data

  defp as_list(data, keys) when is_map(data) do
    Enum.find_value(keys, [], fn k ->
      case Map.get(data, k) do
        list when is_list(list) -> list
        _ -> nil
      end
    end)
  end

  defp as_list(_, _), do: []

  defp dig(map, keys) when is_map(map), do: Enum.find_value(keys, fn k -> Map.get(map, k) end)
  defp dig(_, _), do: nil

  # Drop nil/empty values so AI output stays terse.
  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end
end
