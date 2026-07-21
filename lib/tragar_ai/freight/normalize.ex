defmodule TragarAi.Freight.Normalize do
  @moduledoc """
  Converts FreightWare's raw (camelCase, `es*`-wrapped) JSON into clean,
  snake_case maps. Field maps are mirrored from the Rust reference
  (`tragar_quote_dioxus`) struct definitions — see `TragarAi.Freight` for the
  operations that use them.

  Each `es*` response has already had its outer `response` envelope stripped by
  `TragarAi.Dovetail.Client`, so functions here read from `esWaybills`,
  `esQuotes`, etc. directly.
  """

  # ── Field maps: {freightware_key, clean_key} ────────────────────────────────

  @quote [
    {"quoteNumber", "quote_number"},
    {"quoteObj", "quote_obj"},
    {"quoteDate", "quote_date"},
    {"quoteTime", "quote_time"},
    {"accountReference", "account_reference"},
    {"shipperReference", "shipper_reference"},
    {"serviceType", "service_type"},
    {"serviceTypeDescription", "service_type_description"},
    {"statusCode", "status_code"},
    {"statusDescription", "status_description"},
    {"consignorName", "consignor_name"},
    {"consignorBuilding", "consignor_building"},
    {"consignorStreet", "consignor_street"},
    {"consignorSuburb", "consignor_suburb"},
    {"consignorCity", "consignor_city"},
    {"consignorPostalCode", "consignor_postal_code"},
    {"consignorContactName", "consignor_contact_name"},
    {"consignorContactTel", "consignor_contact_tel"},
    {"consignorSite", "consignor_site"},
    {"consigneeName", "consignee_name"},
    {"consigneeBuilding", "consignee_building"},
    {"consigneeStreet", "consignee_street"},
    {"consigneeSuburb", "consignee_suburb"},
    {"consigneeCity", "consignee_city"},
    {"consigneePostalCode", "consignee_postal_code"},
    {"consigneeContactName", "consignee_contact_name"},
    {"consigneeContactTel", "consignee_contact_tel"},
    {"consigneeSite", "consignee_site"},
    {"chargedAmount", "charged_amount"},
    {"freightCharge", "freight_charge"},
    {"sundryCharge", "sundry_charge"},
    {"insuranceCharge", "insurance_charge"},
    {"taxAmount", "tax_amount"},
    {"collectionInstructions", "collection_instructions"},
    {"deliveryInstructions", "delivery_instructions"},
    {"specialInstructions", "special_instructions"}
  ]

  @quote_item [
    {"quantity", "quantity"},
    {"productCode", "product_code"},
    {"description", "description"},
    {"totalWeight", "total_weight"},
    {"length", "length"},
    {"width", "width"},
    {"height", "height"}
  ]

  @rate [
    {"serviceType", "service_type"},
    {"freightCharge", "freight_charge"},
    {"sundryCharge", "sundry_charge"},
    {"insuranceCharge", "insurance_charge"},
    {"taxAmount", "tax_amount"},
    {"totalCharge", "total_charge"}
  ]

  @sundry [
    {"serviceType", "service_type"},
    {"sundryCode", "sundry_code"},
    {"sundryDescription", "sundry_description"},
    {"sundryDirection", "sundry_direction"},
    {"sundryCharge", "sundry_charge"},
    {"sundryIncluded", "sundry_included"},
    {"sundryCanOverride", "sundry_can_override"}
  ]

  @waybill [
    {"waybillNumber", "waybill_number"},
    {"waybillObj", "waybill_obj"},
    {"waybillDate", "waybill_date"},
    {"accountReference", "account_reference"},
    {"shipperReference", "shipper_reference"},
    {"serviceType", "service_type"},
    {"serviceTypeDescription", "service_type_description"},
    {"consignmentType", "consignment_type"},
    {"consignmentTypeDesc", "consignment_type_desc"},
    {"numberOfItems", "number_of_items"},
    {"costCentre", "cost_centre"},
    {"contents", "contents"},
    {"comments", "comments"},
    {"insuredAmount", "insured_amount"},
    {"receivedAmount", "received_amount"},
    {"freightCharge", "freight_charge"},
    {"sundryCharge", "sundry_charge"},
    {"taxAmount", "tax_amount"},
    {"chargedAmount", "charged_amount"},
    {"consignmentValue", "consignment_value"},
    {"currencyCode", "currency_code"},
    {"statusCode", "status_code"},
    {"statusDescription", "status_description"},
    {"consignorSite", "consignor_site"},
    {"consignorName", "consignor_name"},
    {"consignorBuilding", "consignor_building"},
    {"consignorStreet", "consignor_street"},
    {"consignorSuburb", "consignor_suburb"},
    {"consignorCity", "consignor_city"},
    {"consignorPostalCode", "consignor_postal_code"},
    {"consignorContactName", "consignor_contact_name"},
    {"consignorContactTel", "consignor_contact_tel"},
    {"consigneeSite", "consignee_site"},
    {"consigneeName", "consignee_name"},
    {"consigneeBuilding", "consignee_building"},
    {"consigneeStreet", "consignee_street"},
    {"consigneeSuburb", "consignee_suburb"},
    {"consigneeCity", "consignee_city"},
    {"consigneePostalCode", "consignee_postal_code"},
    {"consigneeContactName", "consignee_contact_name"},
    {"consigneeContactTel", "consignee_contact_tel"},
    {"collectionInstructions", "collection_instructions"},
    {"deliveryInstructions", "delivery_instructions"},
    {"payingParty", "paying_party"}
  ]

  @waybill_item [
    {"waybillNumber", "waybill_number"},
    {"lineNumber", "line_number"},
    {"quantity", "quantity"},
    {"waybillItemObj", "waybill_item_obj"},
    {"productCode", "product_code"},
    {"productCategory", "product_category"},
    {"description", "description"},
    {"totalWeight", "total_weight"},
    {"length", "length"},
    {"width", "width"},
    {"height", "height"},
    {"volumetricWeight", "volumetric_weight"},
    {"actualWeight", "actual_weight"},
    {"packageSize", "package_size"},
    {"packageType", "package_type"}
  ]

  @track_event [
    {"branchCode", "branch_code"},
    {"eventDate", "event_date"},
    {"eventTime", "event_time"},
    {"eventCode", "event_code"},
    {"eventDescription", "event_description"}
  ]

  @pod [
    {"PODDate", "pod_date"},
    {"PODTime", "pod_time"},
    {"numberofParcels", "number_of_parcels"},
    {"receiverName", "receiver_name"},
    {"comments", "comments"},
    {"GRNReference", "grn_reference"},
    {"Endorsements", "endorsements"},
    {"PODImageURL", "pod_image_url"}
  ]

  @site [
    {"siteObj", "site_obj"},
    {"accountReference", "account_reference"},
    {"accountName", "account_name"},
    {"siteReference", "site_code"},
    {"siteName", "site_name"},
    {"building", "building"},
    {"street", "street"},
    {"suburb", "suburb"},
    {"city", "city"},
    {"province", "province"},
    {"postCode", "post_code"},
    {"country", "country"},
    {"telNumber", "tel_number"},
    {"cellNumber", "cell_number"},
    {"faxNumber", "fax_number"},
    {"emailAddress", "email_address"},
    {"userDefault", "user_default"},
    {"siteTypeTLA", "site_type_tla"},
    {"longitude", "longitude"},
    {"latitude", "latitude"},
    {"statusCode", "status_code"}
  ]

  @postal_code [
    {"postalCode", "postal_code"},
    {"suburb", "suburb"},
    {"city", "city"},
    {"province", "province"}
  ]

  @service_type [
    {"serviceTypeCode", "code"},
    {"serviceTypeDescription", "name"},
    {"serviceTypeShortDesc", "short_description"},
    {"serviceClass", "service_class"},
    {"comment", "description"}
  ]

  @consignment_type [
    {"consignmentTypeCode", "consignment_type_code"},
    {"consignmentTypeDesc", "consignment_type_desc"}
  ]

  @product [
    {"productCode", "product_code"},
    {"productDescription", "product_description"},
    {"accountReference", "account_reference"}
  ]

  @account [
    {"accountReference", "account_reference"},
    # The base-data accounts dump uses "name"; other endpoints use "accountName".
    {"accountName", "account_name"},
    {"name", "account_name"},
    {"accountDescription", "account_description"},
    {"accountProfileDesc", "account_description"},
    {"shortName", "short_name"},
    {"otherName", "other_name"},
    {"contactName", "contact_name"},
    {"currentStatus", "status"},
    {"physicalCity", "city"},
    {"eMailAddress", "email"},
    {"telephoneNumber", "telephone"}
  ]

  @branch [
    {"branchCode", "branch_code"},
    {"branchName", "branch_name"},
    {"organisationCode", "organisation_code"},
    {"organisationName", "organisation_name"}
  ]

  @paging [
    {"paged", "paged"},
    {"resultsPerPage", "results_per_page"},
    {"pageNumber", "page_number"},
    {"totalRecords", "total_records"},
    {"totalPages", "total_pages"},
    {"finalPage", "final_page"}
  ]

  @error [
    {"errorCode", "error_code"},
    {"errorDescription", "error_description"},
    {"errorReference", "error_reference"}
  ]

  # ── Entity normalizers ──────────────────────────────────────────────────────

  def quote_entity(m), do: take(m, @quote)
  def quote_item(m), do: take(m, @quote_item)
  def rate(m), do: m |> take(@rate) |> Map.put("sundries", list(m["Sundries"], &sundry/1))
  def sundry(m), do: take(m, @sundry)
  def waybill_item(m), do: take(m, @waybill_item)
  def site(m), do: take(m, @site)
  def postal_code(m), do: take(m, @postal_code)
  def service_type(m), do: take(m, @service_type)
  def consignment_type(m), do: take(m, @consignment_type)
  def product(m), do: take(m, @product)
  def account(m), do: take(m, @account)
  def branch(m), do: take(m, @branch)
  def paging(m), do: take(m, @paging)
  def error(m), do: take(m, @error)

  def waybill(m) do
    take(m, @waybill)
    |> put_nonempty("pod_image_url", waybill_pod_url(m["PODImageUrl"]))
  end

  def track_event(m) do
    take(m, @track_event)
    |> put_nonempty("pod", m["POD"] && pod(m["POD"]))
  end

  def pod(m), do: take(m, @pod)

  # ── Wrapper extractors (take an unwrapped `response` body) ───────────────────

  @doc "Quotes search/detail: returns %{\"quotes\" => [...], \"paging\" => %{}}."
  def quotes(%{"esQuotes" => es}) do
    items = group_by(es["Items"], "quoteNumber")
    sundries = group_by(es["Sundries"], "serviceType")

    quotes =
      es
      |> array("Quotes")
      |> Enum.map(fn q ->
        q
        |> quote_entity()
        |> attach("items", Map.get(items, q["quoteNumber"], []), &quote_item/1)
        |> attach("sundries", Map.get(sundries, q["serviceType"], []), &sundry/1)
        |> put_quote_total()
      end)

    %{"quotes" => quotes, "paging" => paging_of(es, "qtPaging")}
  end

  def quotes(_), do: %{"quotes" => [], "paging" => nil}

  # A created quote often has chargedAmount 0 with the real charges in sundries —
  # surface a computed `total` (freight + tax + sundries) for display.
  defp put_quote_total(quote) do
    charged = num(quote["charged_amount"])

    total =
      if charged > 0 do
        charged
      else
        sundry_total =
          (quote["sundries"] || [])
          |> Enum.reduce(0, fn s, acc -> acc + num(s["sundry_charge"]) end)

        num(quote["freight_charge"]) + num(quote["tax_amount"]) + sundry_total
      end

    Map.put(quote, "total", Float.round(total * 1.0, 2))
  end

  defp num(n) when is_number(n), do: n

  defp num(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      _ -> 0
    end
  end

  defp num(_), do: 0

  @doc "Waybills search/detail: returns %{\"waybills\" => [...], \"paging\" => %{}}."
  def waybills(%{"esWaybills" => es}) do
    items = group_by(es["Items"], "waybillNumber")

    waybills =
      es
      |> array("Waybills")
      |> Enum.map(fn w ->
        attach(waybill(w), "items", Map.get(items, w["waybillNumber"], []), &waybill_item/1)
      end)

    %{"waybills" => waybills, "paging" => paging_of(es, "wtPaging")}
  end

  def waybills(_), do: %{"waybills" => [], "paging" => nil}

  def rates(%{"esRates" => es}), do: es |> array("Rate") |> Enum.map(&rate/1)
  def rates(_), do: []

  @doc """
  Open delivery manifests — the `/multiManifest` "can be closed" list. Returns
  `[%{owning_obj, manifest_number, manifest_date, station_code, manifest_branch,
  status_code, subcontractor_reference}]`. `manifest_branch` is the owning branch
  (the branch closing/scanning the manifest) — the origin anchor for rate-area
  costing. Casing is lenient (FreightWare varies).
  """
  def open_manifests(%{"esOpenManifests" => es}) do
    (array(es, "openManifests") ++ array(es, "OpenManifests"))
    |> Enum.map(&open_manifest/1)
  end

  def open_manifests(_), do: []

  defp open_manifest(m) do
    %{
      "owning_obj" => m["owning_obj"] || m["owningObj"],
      "manifest_number" => m["owning_number"] || m["owningNumber"],
      "manifest_date" => m["manifestDate"] || m["manifest_date"],
      "station_code" => m["stationCode"] || m["station_code"],
      "manifest_branch" => m["manifestBranch"] || m["manifest_branch"],
      "status_code" => m["statusCode"] || m["status_code"],
      "subcontractor_reference" => m["subcontractorReference"] || m["subcontractor_reference"]
    }
  end

  # ── Collections ───────────────────────────────────────────────────────────────

  @doc "Unauthorised collections → `[%{...}]` (FreightWare casing varies; be lenient)."
  def unauthorised_collections(resp),
    do: collections(resp, ["esUnAuthorisedCollections", "esunAuthorisedCollections"])

  @doc "Outstanding (unmanifested) collections → `[%{...}]`."
  def outstanding_collections(resp),
    do: collections(resp, ["esManifestCollections", "esManifestCollection"])

  # The `esXxxCollections` object wraps a single array whose key also varies in
  # casing — take the first list value found under whichever es-key is present.
  defp collections(resp, es_keys) when is_map(resp) do
    es_keys
    |> Enum.find_value(%{}, &Map.get(resp, &1))
    |> first_list()
    |> Enum.map(&collection/1)
  end

  defp collections(_, _), do: []

  # Pass through EVERY field the record carries, snake-cased — so any field the API
  # returns (e.g. a status) is captured rather than silently dropped by a
  # whitelist. Blanks are trimmed out; scalars kept as-is.
  defp collection(m) when is_map(m) do
    for {k, v} <- m, is_binary(k), tv = trim(v), tv not in [nil, ""], into: %{} do
      {Macro.underscore(k), tv}
    end
  end

  defp collection(_), do: %{}

  defp first_list(m) when is_map(m),
    do: Enum.find_value(Map.values(m), [], fn v -> if is_list(v), do: v end)

  defp first_list(_), do: []

  def tracking(%{"esTrackAndTrace" => es}),
    do: es |> array("TrackAndTrace") |> Enum.map(&track_event/1)

  def tracking(_), do: []

  def service_types(%{"esServiceTypes" => es}),
    do: es |> array("ServiceTypes") |> Enum.map(&service_type/1)

  def service_types(_), do: []

  def consignment_types(%{"esConsignmentTypes" => es}),
    do: es |> array("ConsignmentTypes") |> Enum.map(&consignment_type/1)

  def consignment_types(_), do: []

  def products(%{"esProducts" => es}), do: es |> array("Products") |> Enum.map(&product/1)
  def products(_), do: []

  def accounts(%{"esAccounts" => es}), do: es |> array("Accounts") |> Enum.map(&account/1)
  def accounts(_), do: []

  def sites(%{"esSites" => es}), do: es |> array("Sites") |> Enum.map(&site/1)
  def sites(_), do: []

  def postal_codes(%{"esPostalCodes" => es}),
    do: es |> array("PostalCodes") |> Enum.map(&postal_code/1)

  def postal_codes(_), do: []

  def branches(%{"esBranches" => es}), do: es |> array("Branches") |> Enum.map(&branch/1)
  def branches(_), do: []

  def errors(%{"esErrors" => es}), do: es |> array("Errors") |> Enum.map(&error/1)
  def errors(_), do: []

  @doc "Quote create response: %{\"quote_obj\" => .., \"quote_number\" => ..}."
  def quote_created(resp) when is_map(resp) do
    obj = resp["quoteObj"]
    %{"quote_obj" => obj, "quote_number" => resp["quoteNumber"] || obj} |> compact()
  end

  @doc """
  POD image bytes: FreightWare returns base64 under esPODImage.PODImage[].
  Returns %{\"img_type\" => .., \"img_data\" => ..} or nil.
  """
  def pod_image(%{"esPODImage" => es}) do
    case array(es, "PODImage") do
      [img | _] -> %{"img_type" => img["IMGType"], "img_data" => img["IMGData"]} |> compact()
      _ -> nil
    end
  end

  def pod_image(_), do: nil

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp take(map, fields) when is_map(map) do
    for {fw, clean} <- fields,
        v = trim(Map.get(map, fw)),
        v not in [nil, ""],
        into: %{},
        do: {clean, v}
  end

  defp take(_, _), do: %{}

  # FreightWare leaves stray newlines/spaces in text fields; trim them so blanks
  # drop out and the UI stays clean. Non-strings pass through untouched.
  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v), do: v

  defp list(nil, _fun), do: []
  defp list(items, fun) when is_list(items), do: Enum.map(items, fun)
  defp list(_, _), do: []

  defp array(map, key) when is_map(map) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp array(_, _), do: []

  defp group_by(nil, _key), do: %{}
  defp group_by(items, key) when is_list(items), do: Enum.group_by(items, &Map.get(&1, key))
  defp group_by(_, _), do: %{}

  defp attach(map, _key, [], _fun), do: map
  defp attach(map, key, items, fun), do: Map.put(map, key, Enum.map(items, fun))

  defp paging_of(es, primary_key) do
    case array(es, primary_key) ++ array(es, "Paging") do
      [p | _] -> paging(p)
      _ -> nil
    end
  end

  # Waybill POD link → standardised Dovetail viewer URL (mirrors the Rust transform).
  defp waybill_pod_url(nil), do: nil
  defp waybill_pod_url(""), do: nil

  defp waybill_pod_url(url) when is_binary(url) do
    key =
      cond do
        String.contains?(url, "dovetail.co.za") and String.contains?(url, "key=") ->
          url |> String.split("key=") |> List.last()

        String.contains?(url, "/FreightWare/V2/system/pod/") ->
          url |> String.split("/FreightWare/V2/system/pod/") |> List.last()

        String.contains?(url, "/system/pod/") ->
          url |> String.split("/system/pod/") |> List.last()

        true ->
          String.trim_leading(url, "/")
      end

    "#{pod_image_base()}?#{key}"
  end

  # The Dovetail POD viewer base — DERIVED from the configured Dovetail base url
  # (same host; the FWO viewer path, FWO_UAT on UAT), so it always follows the
  # environment instead of a hardcoded url. An explicit `:pod_image_base` config
  # overrides it.
  defp pod_image_base do
    cfg = Application.get_env(:tragar_ai, TragarAi.Dovetail.Client, [])
    Keyword.get(cfg, :pod_image_base) || derive_pod_base(Keyword.get(cfg, :base_url))
  end

  defp derive_pod_base(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)
    segment = if String.contains?(base_url, "UAT"), do: "FWO_UAT", else: "FWO"
    "#{uri.scheme}://#{uri.host}/#{segment}/views/viewImage.html"
  end

  defp derive_pod_base(_), do: "https://tragar-db.dovetail.co.za/FWO/views/viewImage.html"

  defp put_nonempty(map, _key, nil), do: map
  defp put_nonempty(map, _key, ""), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
