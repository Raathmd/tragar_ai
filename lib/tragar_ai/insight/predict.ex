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
    min_sell = Keyword.get(opts, :min_sell, 250_000.0)
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
