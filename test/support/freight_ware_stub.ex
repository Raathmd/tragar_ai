defmodule TragarAi.FreightWareStub do
  @moduledoc """
  Helpers for `Req.Test` stubs of the Dovetail/FreightWare client.

  `get_waybill/1` and `get_quote/1` fetch by number through the COLLECTION
  endpoint (`/waybills/`, `/quotes/`) with the id carried in the `esfilters`
  header — the same URL a search hits — so stubs distinguish a by-number fetch
  from a search by the header, not the path.
  """
  import Plug.Conn, only: [get_req_header: 2]

  @doc "The esfilters map (filterName => filterValue) sent with a stubbed request."
  def esfilters(conn) do
    with [json | _] <- get_req_header(conn, "esfilters"),
         {:ok, %{"Filters" => filters}} <- Jason.decode(json) do
      Map.new(filters, &{&1["filterName"], &1["filterValue"]})
    else
      _ -> %{}
    end
  end

  @doc "True when this request is a by-number waybill fetch for `number`."
  def waybill_number?(conn, number),
    do: String.ends_with?(conn.request_path, "/waybills/") and esfilters(conn)["waybillNumber"] == number

  @doc "True when this request is a by-number quote fetch for `number`."
  def quote_number?(conn, number),
    do: String.ends_with?(conn.request_path, "/quotes/") and esfilters(conn)["quoteNumber"] == number

  @doc "True when this request is an account-scoped shipper-reference waybill search."
  def shipper_search?(conn),
    do: String.ends_with?(conn.request_path, "/waybills/") and Map.has_key?(esfilters(conn), "shipperReference")
end
