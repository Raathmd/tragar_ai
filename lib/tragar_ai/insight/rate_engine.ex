defmodule TragarAi.Insight.RateEngine do
  @moduledoc """
  Expected 3rd-party delivery cost from the live FreightWare rate card (Half 2).

  For an open delivery manifest, ranks the candidate 3rd-party suppliers by what
  each *would* charge to deliver its waybills — the "who's cheapest" comparison.
  It is a comparison of alternatives, not a lookup of the assigned party (many
  manifests run on Tragar's own fleet, which has no rate card).

  The chain, reverse-engineered + validated against the replica:

      manifest (fwt_manifest.manifest_reference)
        → its waybills            (fwt_waybill_allocation → fwt_waybill)
        → each destination        (fwt_waybill.consignee_postcode_obj)
        → that supplier's area     (fwc_rate_area_postcode, FWMSC + owning_obj = supplier)
        → that supplier's rate     (fwm_entity_rate, FWMSC, to_rate_area = area, effective)
        → weight band              (fwm_rate_table, from_unit ≤ chargable_units < to_unit)
        → per-waybill expected cost = base_amount + increment_amount ×
                                       ((weight − from_unit) / increment_unit)

  Rates are read LIVE (small, effective-dated, must be current), in-app, per
  manifest on demand — never batched — so a single manifest's handful of waybills
  keeps the query light. The raw rate rows come back from `Insight.Db`; the
  per-waybill formula, latest-effective pick, and summing happen here in Elixir
  (robust, and keeps the SQL a plain SELECT).
  """

  alias TragarAi.Insight.Db

  @doc """
  Rank candidate 3rd-party suppliers for a manifest, keyed by its numeric
  `manifest_obj` (the FreightWare API's `owning_obj`), by total expected cost
  across its waybills, cheapest first. Returns `{:ok, [row]}` where each row is:

      %{supplier_ref, supplier_name, waybills_priced, total_expected}

  `waybills_priced` is how many of the manifest's waybills that supplier can
  cover — a full alternative covers them all; a partial one covers fewer.

  Keyed on `manifest_obj` (not the reference string) because the API's delivery-
  manifest number and `fwt_manifest.manifest_reference` are different identifiers.
  """
  @spec rank_manifest_suppliers(String.t()) :: {:ok, [map()]} | {:error, term()}
  def rank_manifest_suppliers(manifest_obj) when is_binary(manifest_obj) do
    with {:ok, obj} <- sanitize_obj(manifest_obj),
         {:ok, rows} <- Db.query_rows(rows_sql(obj)) do
      {:ok, rank(rows)}
    end
  end

  # --- ranking ------------------------------------------------------------

  defp rank(rows) do
    rows
    |> Enum.group_by(&Map.get(&1, "supplier_ref"))
    |> Enum.map(fn {ref, supplier_rows} ->
      # Per waybill, keep only the latest-effective rate version, then price it.
      waybill_costs =
        supplier_rows
        |> Enum.group_by(&Map.get(&1, "waybill_obj"))
        |> Enum.map(fn {_wb, wb_rows} ->
          wb_rows |> Enum.max_by(&(&1["effective_date"] || "")) |> waybill_cost()
        end)

      %{
        supplier_ref: ref,
        supplier_name: supplier_rows |> hd() |> Map.get("supplier_name"),
        waybills_priced: length(waybill_costs),
        total_expected: waybill_costs |> Enum.sum() |> Float.round(2)
      }
    end)
    |> Enum.sort_by(& &1.total_expected)
  end

  # base + increment × ((weight − from) / increment_unit); flat when increment_unit = 0.
  defp waybill_cost(row) do
    base = num(row["base_amount"])
    increment = num(row["increment_amount"])
    increment_unit = num(row["increment_unit"])
    from_unit = num(row["from_unit"])
    weight = num(row["chargable_units"])

    if increment_unit > 0.0,
      do: base + increment * ((weight - from_unit) / increment_unit),
      else: base
  end

  defp num(nil), do: 0.0

  defp num(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # --- query --------------------------------------------------------------

  # Raw per-(waybill, supplier, effective-version, band) rows for one manifest.
  # Kept a plain SELECT; the Elixir side dedups/prices. `to_rate_area` keying and
  # owning_obj = supplier were both confirmed against the replica. `obj` is a bare
  # integer (validated by sanitize_obj), compared to the numeric manifest_obj.
  defp rows_sql(obj) do
    today = Date.utc_today() |> Date.to_iso8601()

    """
    SELECT c.contractor_reference AS supplier_ref, c.contractor_name AS supplier_name, \
    w.waybill_obj, w.chargable_units, er.effective_date, rt.from_unit, rt.base_amount, \
    rt.increment_amount, rt.increment_unit \
    FROM PUB.fwt_manifest m \
    JOIN PUB.fwt_waybill_allocation a ON a.manifest_obj = m.manifest_obj \
    JOIN PUB.fwt_waybill w ON w.waybill_obj = a.waybill_obj \
    JOIN PUB.fwc_rate_area_postcode pc ON pc.postcode_obj = w.consignee_postcode_obj \
    AND pc.owning_entity_mnemonic = 'FWMSC' \
    JOIN PUB.fwm_station_contractor c ON c.station_contractor_obj = pc.owning_obj \
    JOIN PUB.fwm_entity_rate er ON er.owning_entity_mnemonic = 'FWMSC' \
    AND er.owning_obj = pc.owning_obj AND er.to_rate_area_obj = pc.rate_area_obj \
    AND (er.cease_date IS NULL OR er.cease_date >= '#{today}') \
    JOIN PUB.fwm_rate_table rt ON rt.entity_rate_obj = er.entity_rate_obj \
    AND w.chargable_units >= rt.from_unit AND w.chargable_units < rt.to_unit \
    WHERE m.manifest_obj = #{obj}
    """
  end

  # `owning_obj` comes from the API as a number (sometimes "12345.0"); take the
  # integer part and allow digits only, so it's a safe bare numeric literal.
  defp sanitize_obj(obj) do
    digits = obj |> to_string() |> String.trim() |> String.split(".") |> List.first()

    if String.match?(digits, ~r/^[0-9]{1,20}$/),
      do: {:ok, digits},
      else: {:error, :invalid_manifest_obj}
  end
end
