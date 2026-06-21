defmodule TragarAi.Harmonize do
  @moduledoc """
  Reconcile a domain entity from its `TragarAi.Sources.SourceRecord`s.

  Each source contributes its own pieces; sources **do not override each other**.
  When two sources provide the same field, a deterministic source priority
  decides the owner (higher priority wins); otherwise every source's distinct
  pieces are simply combined. Returns `%{fields: %{string => value}, sources: [..]}`.
  """

  # Higher priority (earlier) owns a contested field.
  @priority ["FreightWare", "Pastel", "Vantage", "FleetIT", "Granite", "Freshdesk"]

  @spec project([struct()]) :: %{fields: map(), sources: [String.t()]}
  def project(records) do
    fields =
      records
      |> Enum.sort_by(&priority_index(&1.source))
      |> Enum.reduce(%{}, fn record, acc ->
        record
        |> Map.get(:data, %{})
        |> drop_blanks()
        |> Enum.reduce(acc, fn {k, v}, a -> Map.put_new(a, to_string(k), v) end)
      end)

    sources = records |> Enum.map(& &1.source) |> Enum.uniq()
    %{fields: fields, sources: sources}
  end

  defp priority_index(source) do
    case Enum.find_index(@priority, &(&1 == source)) do
      nil -> length(@priority)
      i -> i
    end
  end

  defp drop_blanks(map),
    do: for({k, v} <- map, not is_nil(v) and v != "", into: %{}, do: {k, v})
end
