defmodule TragarAi.Freight do
  @moduledoc """
  High-level FreightWare (Dovetail) API — the full set of endpoint calls from
  the Rust reference, returning clean normalized data (`TragarAi.Freight.Normalize`).

  Read operations (status, tracking, waybill/quote lookup, base data) back the
  support-assist tool; the quote operations (quick quote, create, accept, reject)
  are available for staff creating quotes on a customer's behalf. Transport,
  auth and the `esfilters` header are handled by `TragarAi.Dovetail.Client`.
  """

  alias TragarAi.Dovetail.Client
  alias TragarAi.Freight.Normalize

  # ── Quotes ──────────────────────────────────────────────────────────────────

  @doc "Instant rates for a shipment. `params` is a clean map (see `build_shipment/1`)."
  def quick_quote(params) do
    body = %{"esShipment" => build_shipment(params)}

    with {:ok, resp} <- Client.post("/quotes/quick", body) do
      {:ok, Normalize.rates(resp)}
    end
  end

  @doc "Create a formal quote. Returns %{\"quote_obj\", \"quote_number\"}."
  def create_quote(params) do
    body = %{"esQuotes" => build_quote(params)}

    with {:ok, resp} <- Client.post("/quotes/", body) do
      {:ok, Normalize.quote_created(resp)}
    end
  end

  @doc "Fetch one quote (with items + sundries) by FreightWare object id."
  def get_quote(quote_obj) do
    with {:ok, resp} <- Client.get("/quotes/#{quote_obj}/") do
      {:ok, resp |> Normalize.quotes() |> first("quotes")}
    end
  end

  @doc """
  Search quotes. `params` keys: `quote_number`, `account_reference`,
  `status_code`, `date_from`, `date_to`, `shipper_reference`, `page`, `limit`.
  Returns %{quotes: [...], paging: %{}}.
  """
  def search_quotes(params \\ %{}) do
    with :ok <- require_account(params) do
      filters =
        build_filters(params, [
          {"quoteNumber", :quote_number},
          {"accountReference", :account_reference},
          {"statusCode", :status_code},
          {"dateFrom", :date_from},
          {"dateTo", :date_to},
          {"shipperReference", :shipper_reference}
        ])

      with {:ok, resp} <- Client.get("/quotes/", filters: filters, paging: paging(params, 10)) do
        {:ok, Normalize.quotes(resp)}
      end
    end
  end

  @doc "Accept a quote. `acceptance_type` is \"PAID\" or \"ACCOUNT\"."
  def accept_quote(quote_obj, acceptance_type, params \\ %{}) do
    query = [
      acceptedBy: params[:accepted_by] || "",
      acceptReference: params[:accept_reference] || "",
      createCollection: params[:create_collection] || false,
      collectionIsQuoteNumber: params[:collection_is_quote_number] || false,
      createWaybill: params[:create_waybill] || false,
      waybillNumber: params[:waybill_number] || ""
    ]

    with {:ok, resp} <-
           Client.put("/quotes/#{quote_obj}/accept/#{acceptance_type}", %{}, params: query) do
      case Normalize.errors(resp) do
        [] -> {:ok, resp}
        errors -> {:error, {:freightware, errors}}
      end
    end
  end

  @doc "Reject a quote, with an optional reason."
  def reject_quote(quote_obj, reason \\ nil) do
    query = if reason, do: [rejectReason: reason], else: []

    with {:ok, _resp} <- Client.put("/quotes/#{quote_obj}/reject", %{}, params: query) do
      :ok
    end
  end

  # ── Waybills & tracking ───────────────────────────────────────────────────────

  @doc "Fetch one waybill (with items) by number."
  def get_waybill(waybill_number) do
    filters = [{"waybillNumber", waybill_number}]
    paging = %{paged: true, results_per_page: 1, page_number: 1}

    with {:ok, resp} <-
           Client.get("/waybills/#{waybill_number}/", filters: filters, paging: paging) do
      {:ok, resp |> Normalize.waybills() |> first("waybills")}
    end
  end

  @doc """
  Search waybills. `params` keys: `waybill_number`, `account_reference`,
  `status_code`, `date_from`, `date_to`, `shipper_reference`, `page`, `limit`.
  """
  def search_waybills(params \\ %{}) do
    with :ok <- require_account(params) do
      # An unbounded waybill search times out — always bound it by a date window.
      params = put_default_dates(params)

      filters =
        build_filters(params, [
          {"waybillNumber", :waybill_number},
          {"accountReference", :account_reference},
          {"statusCode", :status_code},
          {"dateFrom", :date_from},
          {"dateTo", :date_to},
          {"shipperReference", :shipper_reference}
        ])

      with {:ok, resp} <- Client.get("/waybills/", filters: filters, paging: paging(params, 50)) do
        {:ok, Normalize.waybills(resp)}
      end
    end
  end

  # Default to roughly the last year so the search is bounded (and reachable).
  defp put_default_dates(params) do
    if params[:date_from] || params["date_from"] do
      params
    else
      today = Date.utc_today()

      params
      |> Map.put(:date_from, Date.to_iso8601(Date.add(today, -365)))
      |> Map.put(:date_to, Date.to_iso8601(today))
    end
  end

  @doc "Track & trace by reference. `ref_type` is `:waybills` or `:quotes`."
  def track_and_trace(ref_type, reference) do
    with {:ok, resp} <- Client.get("/#{ref_type}/#{reference}/trackAndTrace") do
      {:ok, Normalize.tracking(resp)}
    end
  end

  @doc "Fetch a POD image (base64) by its key: %{\"img_type\", \"img_data\"} | nil."
  def pod_image(key) do
    with {:ok, resp} <- Client.get("/document/image/#{key}") do
      {:ok, Normalize.pod_image(resp)}
    end
  end

  # ── Base data ─────────────────────────────────────────────────────────────────

  def service_types(valid_for_type \\ nil) do
    filters = if valid_for_type, do: [{"validForType", valid_for_type}], else: []

    with {:ok, resp} <- Client.get("/system/baseData/serviceTypes", filters: filters) do
      {:ok, Normalize.service_types(resp)}
    end
  end

  @doc """
  Resolve free text (e.g. "Economy", "overnight", or a code) to a real
  FreightWare service type. Matches by exact code first (so the 3 OVERNIGHT
  services don't collide), then exact name, then a contains match. Returns the
  full service-type map; take `"code"` for the quote `serviceType`.
  """
  def resolve_service_type(text) when is_binary(text) do
    t = text |> String.trim() |> String.downcase()

    with {:ok, types} <- service_types() do
      down = fn v -> v |> to_string() |> String.downcase() end

      match =
        Enum.find(types, &(down.(&1["code"]) == t)) ||
          Enum.find(types, &(down.(&1["name"]) == t)) ||
          (t != "" &&
             Enum.find(types, fn st ->
               String.contains?(down.(st["name"]), t) or
                 String.contains?(down.(st["short_description"]), t)
             end))

      case match do
        nil -> {:error, :no_service_match}
        st -> {:ok, st}
      end
    end
  end

  def resolve_service_type(_), do: {:error, :no_service_match}

  def consignment_types do
    with {:ok, resp} <- Client.get("/system/baseData/consignmentTypes") do
      {:ok, Normalize.consignment_types(resp)}
    end
  end

  def products(params \\ %{}) do
    filters =
      build_filters(params, [
        {"searchString", :search_string},
        {"accountReference", :account_reference}
      ])

    with {:ok, resp} <- Client.get("/system/baseData/products", filters: filters) do
      {:ok, Normalize.products(resp)}
    end
  end

  def accounts do
    with {:ok, resp} <- Client.get("/system/baseData/accounts") do
      {:ok, Normalize.accounts(resp)}
    end
  end

  @doc "Fetch a single account by reference (account-scoped, individual retrieval)."
  def get_account(account_reference) when is_binary(account_reference) do
    with {:ok, resp} <-
           Client.get("/system/baseData/accounts",
             filters: [{"accountReference", account_reference}]
           ) do
      case Normalize.accounts(resp) do
        [account | _] -> {:ok, account}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "Search sites by free-text string."
  def search_sites(query) do
    filters = [{"searchString", query}]
    paging = %{paged: true, results_per_page: 20, page_number: 1}

    with {:ok, resp} <- Client.get("/system/baseData/sites", filters: filters, paging: paging) do
      {:ok, Normalize.sites(resp)}
    end
  end

  @doc "Fetch a single site by its exact site code."
  def site_by_code(code) do
    with {:ok, resp} <- Client.get("/system/baseData/sites", filters: [{"siteRef", code}]) do
      site = resp |> Normalize.sites() |> Enum.find(&(&1["site_code"] == code))
      {:ok, site}
    end
  end

  @doc "Sites base-data search with the full filter set."
  def sites(params \\ %{}) do
    filters = [
      {"defaultOnly", params[:default_only] || "NO"},
      {"siteRef", params[:site_ref] || ""},
      {"siteName", params[:site_name] || ""},
      {"siteTypeTLA", params[:site_type_tla] || ""},
      {"accountNumber", params[:account_number] || ""},
      {"searchString", params[:search_string] || ""}
    ]

    paging = %{paged: false, results_per_page: 100, page_number: 1}

    with {:ok, resp} <- Client.get("/system/baseData/sites", filters: filters, paging: paging) do
      {:ok, Normalize.sites(resp)}
    end
  end

  def postal_codes(query) do
    with {:ok, resp} <-
           Client.get("/system/baseData/postalCodes", filters: [{"searchString", query}]) do
      {:ok, Normalize.postal_codes(resp)}
    end
  end

  def user_branches(username) do
    with {:ok, resp} <- Client.get("/system/auth/login/#{username}/branches") do
      {:ok, Normalize.branches(resp)}
    end
  end

  # ── Request-body builders (mirror the Rust frontend) ────────────────────────

  @doc false
  def build_shipment(params) do
    %{
      "Shipment" => [
        %{
          "accountReference" => params["account_reference"],
          "serviceType" => params["service_type"],
          "consignmentType" => "",
          "consignorSite" => params["consignor_site"],
          "consignorName" => params["consignor_name"],
          "consignorBuilding" => params["consignor_building"],
          "consignorStreet" => params["consignor_street"],
          "consignorSuburb" => params["consignor_suburb"],
          "consignorCity" => params["consignor_city"],
          "consignorPostalCode" =>
            params["collection_postal_code"] || params["consignor_postal_code"],
          "consignorContactName" => params["consignor_contact_name"],
          "consignorContactTel" => params["consignor_contact_tel"],
          "consigneeSite" => params["consignee_site"],
          "consigneeName" => params["consignee_name"],
          "consigneeBuilding" => params["consignee_building"],
          "consigneeStreet" => params["consignee_street"],
          "consigneeSuburb" => params["consignee_suburb"],
          "consigneeCity" => params["consignee_city"],
          "consigneePostalCode" =>
            params["delivery_postal_code"] || params["consignee_postal_code"],
          "consigneeContactName" => params["consignee_contact_name"],
          "consigneeContactTel" => params["consignee_contact_tel"],
          "shipmentDate" => today()
        }
        |> compact()
      ],
      "Items" => build_items(params["items"], :string),
      "Sundries" => params["sundries"] || []
    }
  end

  @doc false
  def build_quote(params) do
    %{
      "Quotes" => [
        %{
          "quoteDate" => today(),
          "accountReference" => params["account_reference"],
          "serviceType" => params["service_type"],
          "collectionInstructions" => params["collection_instructions"] || "",
          "deliveryInstructions" => params["delivery_instructions"] || "",
          "consignorName" => params["consignor_name"],
          "consignorPostalCode" =>
            params["collection_postal_code"] || params["consignor_postal_code"],
          "consigneeName" => params["consignee_name"],
          "consigneePostalCode" =>
            params["delivery_postal_code"] || params["consignee_postal_code"]
        }
        |> compact()
      ],
      "Items" => build_items(params["items"], :number)
    }
  end

  defp build_items(nil, _mode), do: []

  defp build_items(items, mode) when is_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, idx} ->
      %{
        "lineNumber" => idx,
        "quantity" => cast(item["quantity"], mode),
        "description" => item["description"],
        "totalWeight" => cast(item["weight"] || item["total_weight"], mode),
        "length" => cast(item["length"], mode),
        "width" => cast(item["width"], mode),
        "height" => cast(item["height"], mode)
      }
      |> compact()
    end)
  end

  defp build_items(_, _), do: []

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Searches are always account-scoped — never an unbounded list.
  defp require_account(params) do
    case params[:account_reference] || params["account_reference"] do
      ref when is_binary(ref) and ref != "" -> :ok
      _ -> {:error, :account_required}
    end
  end

  defp build_filters(params, mapping) do
    for {fw, key} <- mapping, (v = params[key]) not in [nil, ""], do: {fw, v}
  end

  defp paging(params, default_limit) do
    %{
      paged: true,
      results_per_page: params[:limit] || default_limit,
      page_number: params[:page] || 1
    }
  end

  defp first(%{} = result, key), do: result |> Map.get(key, []) |> List.first()

  defp today, do: Date.utc_today() |> Date.to_iso8601()

  defp cast(nil, _), do: nil
  defp cast(v, :string), do: to_string(v)
  defp cast(v, :number), do: v

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
