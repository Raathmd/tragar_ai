defmodule TragarAi.Insight.Predict do
  @moduledoc """
  Nx-powered predictions over the margin rollups — the intelligence layer on top
  of the SQL warehouse.

  For each dimension of a grain it fits a least-squares **trend** on the monthly
  margin-% series (via Nx tensors) and projects it forward, then ranks the
  dimensions whose margin is **eroding** (negative slope) among those with
  material revenue — the "margin at risk" list. Runs in-app on the aggregated
  rollups; no raw data leaves the box.
  """
  import Ecto.Query

  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  @horizon 6

  @doc """
  Top dimensions of `grain` whose margin-% is trending down. Options:
  `:top` (default 10), `:min_sell` total revenue floor (default 250k),
  `:min_points` months of history (default 4).
  """
  @spec at_risk(String.t(), keyword()) :: [map()]
  def at_risk(grain, opts \\ []) do
    top = Keyword.get(opts, :top, 10)
    min_sell = Keyword.get(opts, :min_sell, 100_000.0)
    min_points = Keyword.get(opts, :min_points, 4)

    Repo.all(
      from r in Rollup,
        where: r.grain == ^grain,
        order_by: [asc: r.period_month],
        select: {r.dim_key, r.sell, r.margin}
    )
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {dim, series} -> analyze(dim, series) end)
    |> Enum.filter(fn a ->
      a.dim != "(unknown)" and a.points >= min_points and a.total_sell >= min_sell and
        a.slope < 0
    end)
    |> Enum.sort_by(& &1.slope)
    |> Enum.take(top)
  end

  @doc """
  Dimensions of `grain` flagged for rate attention — the rate-quality signal:
  loss-making (margin < 0, i.e. we charge the client less than the contractor
  costs → a mis-captured rate) or a statistical low-margin outlier (Nx z-score
  ≤ -2 vs peers). Among dimensions with material revenue. Worst first.
  """
  @spec exceptions(String.t(), keyword()) :: [map()]
  def exceptions(grain, opts \\ []) do
    top = Keyword.get(opts, :top, 15)
    min_sell = Keyword.get(opts, :min_sell, 100_000.0)

    dims =
      Repo.all(
        from r in Rollup,
          where: r.grain == ^grain,
          group_by: r.dim_key,
          select: {r.dim_key, sum(r.sell), sum(r.buy)}
      )
      |> Enum.map(fn {dim, sell, buy} ->
        s = to_f(sell)
        b = to_f(buy)

        %{
          dim: dim,
          sell: s,
          buy: b,
          margin: s - b,
          margin_pct: if(s > 0, do: (s - b) / s * 100, else: 0.0)
        }
      end)
      |> Enum.filter(&(&1.dim != "(unknown)" and &1.sell >= min_sell))

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

  defp mean_std([]), do: {0.0, 0.0}

  defp mean_std(vals) do
    t = Nx.tensor(vals)
    mean = t |> Nx.mean() |> Nx.to_number()
    var = t |> Nx.subtract(mean) |> then(&Nx.multiply(&1, &1)) |> Nx.mean() |> Nx.to_number()
    {mean, :math.sqrt(var)}
  end

  @doc "Overall margin-% trend + projection for a grain's single series (e.g. enterprise)."
  @spec trend(String.t()) :: map() | nil
  def trend(grain) do
    series =
      Repo.all(
        from r in Rollup,
          where: r.grain == ^grain,
          order_by: [asc: r.period_month],
          select: {r.dim_key, r.sell, r.margin}
      )

    if series == [], do: nil, else: analyze(grain, series)
  end

  defp analyze(dim, series) do
    mpcts =
      Enum.map(series, fn {_dim, sell, margin} ->
        s = to_f(sell)
        if s > 0, do: to_f(margin) / s * 100.0, else: 0.0
      end)

    n = length(mpcts)
    xs = Enum.map(0..(n - 1), &(&1 * 1.0))
    slope = if n >= 2, do: fit_slope(xs, mpcts), else: 0.0
    latest = List.last(mpcts) || 0.0
    total_sell = series |> Enum.map(fn {_, sell, _} -> to_f(sell) end) |> Enum.sum()

    %{
      dim: dim,
      points: n,
      slope: Float.round(slope, 3),
      latest_pct: Float.round(latest, 1),
      projected_pct: Float.round(latest + slope * @horizon, 1),
      total_sell: total_sell
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

  defp to_f(nil), do: 0.0
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_number(n), do: n * 1.0
end
