defmodule TragarAi.Insight.Predict do
  @moduledoc """
  Nx-powered predictions over the margin rollups — the intelligence layer on top
  of the SQL warehouse.

  Fits a least-squares **trend** on each dimension's monthly margin-% series (via
  Nx tensors) and projects it forward, then ranks dimensions whose margin is
  eroding (at-risk) or that look mis-rated (exceptions). Respects the selected
  `year` (nil = all years) and excludes **inactive** dimensions — those with no
  data in the recent window (so churned customers/suppliers don't show up). Runs
  in-app on the aggregated rollups; no raw data leaves the box.
  """
  import Ecto.Query

  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  @horizon 6
  @recency_days 185

  @doc "Client/lane dimensions with the steepest declining margin, still active."
  @spec at_risk(String.t(), integer() | nil, keyword()) :: [map()]
  def at_risk(grain, year \\ nil, opts \\ []) do
    top = Keyword.get(opts, :top, 10)
    min_sell = Keyword.get(opts, :min_sell, 100_000.0)
    min_points = Keyword.get(opts, :min_points, 4)
    {rows, cutoff} = load_series(grain, year)

    rows
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {dim, series} -> analyze(dim, series) end)
    |> Enum.filter(fn a ->
      a.dim != "(unknown)" and a.points >= min_points and a.total_sell >= min_sell and
        a.slope < 0 and active?(a.latest_month, cutoff)
    end)
    |> Enum.sort_by(& &1.slope)
    |> Enum.take(top)
  end

  @doc "Active dimensions flagged for rate attention: loss-making or low-margin outliers."
  @spec exceptions(String.t(), integer() | nil, keyword()) :: [map()]
  def exceptions(grain, year \\ nil, opts \\ []) do
    top = Keyword.get(opts, :top, 15)
    min_sell = Keyword.get(opts, :min_sell, 100_000.0)
    {rows, cutoff} = load_series(grain, year)

    dims =
      rows
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(&aggregate/1)
      |> Enum.filter(fn d ->
        d.dim != "(unknown)" and d.sell >= min_sell and active?(d.latest_month, cutoff)
      end)

    {mean, std} = mean_std(Enum.map(dims, & &1.margin_pct))

    dims
    |> Enum.map(fn d ->
      z = if std > 0, do: (d.margin_pct - mean) / std, else: 0.0

      reason =
        cond do
          d.margin < 0 -> "loss-making"
          z <= -2.0 -> "low-margin outlier"
          true -> nil
        end

      d |> Map.put(:reason, reason) |> Map.put(:z, Float.round(z, 1))
    end)
    |> Enum.filter(& &1.reason)
    |> Enum.sort_by(& &1.margin_pct)
    |> Enum.take(top)
  end

  @doc "Overall margin-% trend + projection for a grain's single series (e.g. enterprise)."
  @spec trend(String.t(), integer() | nil) :: map() | nil
  def trend(grain, year \\ nil) do
    {rows, _cutoff} = load_series(grain, year)
    if rows == [], do: nil, else: analyze(grain, rows)
  end

  @doc "Margin-% trend + projection for one dimension of a grain (year-scoped). On-demand."
  @spec dim_trend(String.t(), String.t(), integer() | nil) :: map() | nil
  def dim_trend(grain, dim, year \\ nil) do
    {rows, _cutoff} = load_series(grain, year)
    series = Enum.filter(rows, &(elem(&1, 0) == dim))
    if series == [], do: nil, else: analyze(dim, series)
  end

  # ── data + helpers ─────────────────────────────────────────────────────────

  # Returns {rows, recency_cutoff} where rows are {dim, month, sell, buy} sorted
  # by month, and cutoff is (latest month − ~6mo) so callers can drop inactive
  # dimensions.
  defp load_series(grain, year) do
    base =
      from r in Rollup,
        where: r.grain == ^grain,
        order_by: [asc: r.period_month],
        select: {r.dim_key, r.period_month, r.sell, r.buy}

    query =
      if year do
        from r in base,
          where:
            r.period_month >= ^Date.new!(year, 1, 1) and
              r.period_month <= ^Date.new!(year, 12, 31)
      else
        base
      end

    rows = Repo.all(query)
    latest = rows |> Enum.map(&elem(&1, 1)) |> Enum.max(Date, fn -> nil end)
    cutoff = if latest, do: Date.add(latest, -@recency_days), else: nil
    {rows, cutoff}
  end

  defp active?(nil, _cutoff), do: false
  defp active?(_month, nil), do: true
  defp active?(month, cutoff), do: Date.compare(month, cutoff) != :lt

  defp aggregate({dim, series}) do
    sell = series |> Enum.map(fn {_, _, s, _} -> to_f(s) end) |> Enum.sum()
    buy = series |> Enum.map(fn {_, _, _, b} -> to_f(b) end) |> Enum.sum()
    {_, latest_month, _, _} = List.last(series)

    %{
      dim: dim,
      sell: sell,
      buy: buy,
      margin: sell - buy,
      margin_pct: if(sell > 0, do: (sell - buy) / sell * 100, else: 0.0),
      latest_month: latest_month
    }
  end

  defp analyze(dim, series) do
    mpcts =
      Enum.map(series, fn {_, _, sell, buy} ->
        s = to_f(sell)
        if s > 0, do: (s - to_f(buy)) / s * 100.0, else: 0.0
      end)

    n = length(mpcts)
    xs = Enum.map(0..(n - 1), &(&1 * 1.0))
    slope = if n >= 2, do: fit_slope(xs, mpcts), else: 0.0
    latest = List.last(mpcts) || 0.0
    total_sell = series |> Enum.map(fn {_, _, sell, _} -> to_f(sell) end) |> Enum.sum()
    {_, latest_month, _, _} = List.last(series)

    %{
      dim: dim,
      points: n,
      slope: Float.round(slope, 3),
      latest_pct: Float.round(latest, 1),
      projected_pct: Float.round(latest + slope * @horizon, 1),
      total_sell: total_sell,
      latest_month: latest_month
    }
  end

  # Least-squares slope via Nx tensors (BinaryBackend).
  defp fit_slope(xs, ys) do
    x = Nx.tensor(xs)
    y = Nx.tensor(ys)
    dx = Nx.subtract(x, Nx.mean(x))
    dy = Nx.subtract(y, Nx.mean(y))
    num = dx |> Nx.multiply(dy) |> Nx.sum() |> Nx.to_number()
    den = dx |> Nx.multiply(dx) |> Nx.sum() |> Nx.to_number()
    if den == 0.0, do: 0.0, else: num / den
  end

  defp mean_std([]), do: {0.0, 0.0}

  defp mean_std(vals) do
    t = Nx.tensor(vals)
    mean = t |> Nx.mean() |> Nx.to_number()
    var = t |> Nx.subtract(mean) |> then(&Nx.multiply(&1, &1)) |> Nx.mean() |> Nx.to_number()
    {mean, :math.sqrt(var)}
  end

  defp to_f(nil), do: 0.0
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_number(n), do: n * 1.0
end
