defmodule TragarAi.Freight.Statuses do
  @moduledoc """
  Real FreightWare status values.

  FreightWare exposes `GET /system/util/statuses/{waybill|quote}`, but it 500s on
  the UAT instance — so, like the original app, we use static definitions. The
  search filter sends the **code** (e.g. `POD`, confirmed against the API; the
  long display names like "DELIVERED" are NOT accepted as filter values).
  """

  # {code, label} — codes observed live + the FreightWare status set.
  @waybill [
    {"TOD", "To Deliver"},
    {"OND", "On Delivery"},
    {"POD", "POD (delivered)"},
    {"DLV", "Delivered"},
    {"DEL", "Deleted"}
  ]

  # Quote status codes (from the FreightWare quote status list).
  @quote [
    {"CRT", "Created"},
    {"ACC", "Accepted"},
    {"REJ", "Rejected"},
    {"CAN", "Cancelled"},
    {"AWA", "Awaiting auth"},
    {"AUT", "Authorised"},
    {"CRQ", "Requoted"},
    {"PRC", "Processed"}
  ]

  # A waybill that has reached the customer.
  @delivered_codes ~w(POD DLV)

  def waybill, do: @waybill
  def quote, do: @quote
  def waybill_codes, do: Enum.map(@waybill, &elem(&1, 0))

  @doc "Is this a delivered waybill (by code or description)?"
  def delivered?(waybill) when is_map(waybill) do
    code = waybill["status_code"] |> to_string() |> String.upcase()

    desc =
      (waybill["status_description"] || waybill["status"] || "")
      |> to_string()
      |> String.downcase()

    code in @delivered_codes or desc in ["delivered", "pod"]
  end

  @doc "Is this a deleted waybill?"
  def deleted?(waybill) when is_map(waybill) do
    code = waybill["status_code"] |> to_string() |> String.upcase()

    desc =
      (waybill["status_description"] || waybill["status"] || "")
      |> to_string()
      |> String.downcase()

    code == "DEL" or desc == "deleted"
  end
end
