defmodule TragarAi.Assist.SearchStrategy do
  @moduledoc """
  The reference-resolution strategy the assist engine uses, as a runtime toggle.

    * `:sequential` — per number, cascade waybill → shipper reference → quote →
      Vantage, stopping at the first source with a valid document.
    * `:fanout` — probe every endpoint for every number concurrently, then
      harmonise.

  Backed by application env so it can be flipped live (e.g. from the settings
  page) without a restart; it falls back to the configured default (`:fanout`)
  on boot. Override the boot default with
  `config :tragar_ai, :search_strategy, :sequential`.
  """

  @key :search_strategy
  @default :fanout
  @strategies [:sequential, :fanout]

  @doc "Every selectable strategy."
  def all, do: @strategies

  @doc "The active strategy."
  def get, do: Application.get_env(:tragar_ai, @key, @default)

  @doc """
  Set the active strategy at runtime. Returns `{:ok, strategy}` for a known
  strategy, or `{:error, :unknown_strategy}` otherwise.
  """
  def set(strategy) when strategy in @strategies do
    Application.put_env(:tragar_ai, @key, strategy)
    {:ok, strategy}
  end

  def set(_), do: {:error, :unknown_strategy}

  @doc "Human-readable label for a strategy."
  def label(:sequential), do: "Sequential cascade"
  def label(:fanout), do: "Parallel fan-out"
  def label(other), do: to_string(other)

  @doc "One-line description of a strategy."
  def describe(:sequential),
    do:
      "Per number, try waybill → shipper reference → quote → Vantage in order and " <>
        "stop at the first hit. Fewer calls when the first source matches."

  def describe(:fanout),
    do:
      "Probe every source for every number at once, then harmonise. Lower latency " <>
        "when the match is a quote or Vantage-only, at the cost of extra calls."

  def describe(_), do: ""
end
