defmodule TragarAi.Freight.Statuses do
  @moduledoc """
  Real FreightWare status values.

  Two sources:

    * **static** `waybill`/`quote` sets below — used by the search filter, which
      sends the **code** (e.g. `POD`, confirmed against the API; long display
      names like "DELIVERED" are NOT accepted as filter values). These stayed
      static because the statuses endpoint 500'd on the UAT instance.

    * **live** `fetch/1` — pulls the status set for a FreightWare *function*
      (`waybill`, `collectionManifest`, `deliveryManifest`, `linehaulManifest`,
      `bagManifest`) from `GET {base}/FreightWare/V2/system/util/statuses/{function}`
      on the prod instance. Used by the supplier ops board to know which delivery-
      manifest statuses mean "open / still changeable" vs finalised.
  """

  alias TragarAi.Dovetail.Client

  # The functions the statuses endpoint accepts.
  @functions ~w(waybill collectionManifest deliveryManifest linehaulManifest bagManifest)

  def functions, do: @functions

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

  @doc """
  Fetch the live status set for a FreightWare function from
  `GET /system/util/statuses/{function}`. Returns `{:ok, [%{code, function}]}`
  or `{:error, reason}` (e.g. `:unknown_function`, or a client/HTTP error).
  """
  def fetch(function) when function in @functions do
    with {:ok, resp} <- Client.get("/system/util/statuses/#{function}") do
      {:ok, parse(resp)}
    end
  end

  def fetch(_), do: {:error, :unknown_function}

  # The response documents an `esStatuses` body with `statusFunction`/`statusCode`
  # per row, wrapped in FreightWare's usual envelope. Dig the list out wherever
  # it landed and normalise the keys, tolerant to casing/wrapping differences.
  defp parse(resp) do
    resp
    |> extract_list()
    |> Enum.map(fn s ->
      %{
        code: s["statusCode"] || s["status_code"] || s["StatusCode"],
        function: s["statusFunction"] || s["status_function"] || s["StatusFunction"]
      }
    end)
    |> Enum.reject(&is_nil(&1.code))
  end

  defp extract_list(list) when is_list(list), do: list

  defp extract_list(%{} = map) do
    cond do
      is_list(map["statuses"]) -> map["statuses"]
      map["esStatuses"] -> extract_list(map["esStatuses"])
      map["response"] -> extract_list(map["response"])
      map["Statuses"] -> extract_list(map["Statuses"])
      true -> map |> Map.values() |> Enum.find_value([], &nested_list/1)
    end
  end

  defp extract_list(_), do: []

  defp nested_list(v) when is_list(v), do: v
  defp nested_list(%{} = v), do: extract_list(v)
  defp nested_list(_), do: false

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
