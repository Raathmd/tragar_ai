defmodule TragarAi.Insight.DeliveryAudit do
  @moduledoc """
  Backs the delivery-audit view (`TragarAiWeb.DeliveryAuditLive`): a visual,
  per-waybill window on what the expected-cost calc is finding.

  The costed facts (customer sell, supplier buy, expected, priced/uncosted) come
  from the materialised warehouse (`insight_waybill_costs`) — fast, and filterable
  by supplier or customer. The RESOLUTION detail behind each expected — the
  delivery town + postal code, the resolved subcontractor rate area, and the
  single chosen rate — is enriched LIVE from the replica via `RateEngine.audit/1`,
  scoped to just the page's waybills (indexed by `waybill_obj`, so it stays small).

  A manifest filter first resolves the manifest's (tripsheet's) waybills off the
  replica, then filters the warehouse to those — one manifest is a bounded set.
  Only materialised months have warehouse rows; older/un-refreshed months come
  back empty (run a warehouse refresh to populate them).
  """

  import Ecto.Query

  alias TragarAi.Insight.Db
  alias TragarAi.Insight.RateEngine
  alias TragarAi.Insight.WaybillCost
  alias TragarAi.Repo

  @per_page 100

  @spec per_page() :: pos_integer()
  def per_page, do: @per_page

  @typedoc "all | {:supplier, ref} | {:customer, name} | {:manifest, [obj]}"
  @type filter ::
          :all | {:supplier, String.t()} | {:customer, String.t()} | {:manifest, [String.t()]}

  @doc """
  A page of 3rd-party (non-own-fleet) deliveries from the warehouse for the month,
  narrowed by `filter`, plus the total count. Returns `{rows, total}` where each
  row is a `WaybillCost` struct.
  """
  @spec list(pos_integer(), pos_integer(), filter(), pos_integer()) ::
          {[WaybillCost.t()], non_neg_integer()}
  def list(year, month, filter, page) do
    {lo, hi} = month_bounds(year, month)

    base =
      from(c in WaybillCost,
        where: c.waybill_date >= ^lo and c.waybill_date <= ^hi and c.own_fleet == false
      )

    q = apply_filter(base, filter)
    total = Repo.aggregate(q, :count)

    rows =
      q
      |> order_by([c], asc: c.waybill_date, asc: c.waybill_number)
      |> limit(^@per_page)
      |> offset(^((page - 1) * @per_page))
      |> Repo.all()

    {rows, total}
  end

  defp apply_filter(q, {:supplier, ref}), do: from(c in q, where: c.contractor_reference == ^ref)
  defp apply_filter(q, {:customer, name}), do: from(c in q, where: c.account_name == ^name)
  defp apply_filter(q, {:manifest, objs}), do: from(c in q, where: c.waybill_obj in ^objs)
  defp apply_filter(q, _), do: q

  @doc "Distinct supplier refs seen in the month (for the filter dropdown)."
  @spec suppliers(pos_integer(), pos_integer()) :: [String.t()]
  def suppliers(year, month), do: distinct_field(year, month, :contractor_reference)

  @doc "Distinct customer names seen in the month (for the filter dropdown)."
  @spec customers(pos_integer(), pos_integer()) :: [String.t()]
  def customers(year, month), do: distinct_field(year, month, :account_name)

  defp distinct_field(year, month, field) do
    {lo, hi} = month_bounds(year, month)

    from(c in WaybillCost,
      where: c.waybill_date >= ^lo and c.waybill_date <= ^hi and c.own_fleet == false,
      where: not is_nil(field(c, ^field)) and field(c, ^field) != "",
      distinct: true,
      select: field(c, ^field),
      order_by: field(c, ^field)
    )
    |> Repo.all()
  end

  @doc """
  Resolve a manifest to its waybill objs off the replica (tripsheet → parcels →
  waybills). `ref_or_obj` may be a numeric `tripsheet_obj` or a `trip_reference`.
  """
  @spec manifest_waybill_objs(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def manifest_waybill_objs(ref_or_obj) do
    ref_or_obj = to_string(ref_or_obj) |> String.trim()

    pred =
      case sanitize_obj(ref_or_obj) do
        nil -> "ts.trip_reference = '#{escape(ref_or_obj)}'"
        obj -> "ts.tripsheet_obj = #{obj}"
      end

    sql =
      "SELECT DISTINCT wp.waybill_obj AS waybill_obj " <>
        "FROM PUB.fwt_tripsheet ts " <>
        "JOIN PUB.fwt_parcel_tripsheet pt ON pt.tripsheet_obj = ts.tripsheet_obj " <>
        "JOIN PUB.fwt_waybill_parcel wp ON wp.waybill_parcel_obj = pt.waybill_parcel_obj " <>
        "WHERE " <> pred

    case Db.query_rows(sql) do
      {:ok, rows} ->
        {:ok, rows |> Enum.map(& &1["waybill_obj"]) |> Enum.reject(&(&1 in [nil, ""]))}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Live resolution for the given waybill objs — `%{waybill_obj => audit_row}` from
  `RateEngine.audit/1`. Empty map for an empty/blank list.
  """
  @spec resolve([String.t()]) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def resolve(objs) do
    clean = objs |> Enum.map(&sanitize_obj/1) |> Enum.reject(&is_nil/1)

    if clean == [] do
      {:ok, %{}}
    else
      case RateEngine.audit("w.waybill_obj IN (#{Enum.join(clean, ",")})") do
        {:ok, rows} -> {:ok, Map.new(rows, &{&1.waybill_obj, &1})}
        {:error, _} = err -> err
      end
    end
  end

  defp month_bounds(year, month) do
    lo = Date.new!(year, month, 1)
    {lo, Date.end_of_month(lo)}
  end

  # Bare integer (drop any ".0"), digits only — a safe numeric literal, or nil.
  defp sanitize_obj(v) do
    digits = v |> to_string() |> String.trim() |> String.split(".") |> List.first()
    if String.match?(digits, ~r/^[0-9]{1,20}$/), do: digits, else: nil
  end

  # A trip_reference literal — allow only safe chars, strip the rest.
  defp escape(s), do: String.replace(s, ~r/[^A-Za-z0-9_\-\/]/, "")
end
