defmodule TragarAiWeb.CollectionsLive do
  @moduledoc """
  Staff view of FreightWare collections for the current branch: those awaiting
  authorisation, and those still outstanding (not yet on a collection manifest).

  A LiveView over the socket: the server re-polls FreightWare every 10s, flashes
  collections that are newly seen, and colours each row by how long it has been
  open (age since it first appeared / its collection date).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Freight

  # Auto-refresh interval, adjustable live from the header. Defaults to 1 minute —
  # the FreightWare collections fetch is heavy (~15s for the full branch set), so
  # polling faster than that just piles requests up.
  @default_poll_ms 60_000
  @poll_options [{"30s", 30_000}, {"1m", 60_000}, {"2m", 120_000}, {"5m", 300_000}, {"Off", 0}]

  # Age thresholds (seconds) for the open-duration highlight.
  @amber_after 30 * 60
  @red_after 2 * 60 * 60
  # A collection first seen within this window still reads as "new".
  @new_within 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        unauthorised: [],
        outstanding: [],
        unauthorised_error: nil,
        outstanding_error: nil,
        first_seen: %{},
        new_keys: MapSet.new(),
        now: DateTime.utc_now(),
        updated_at: nil,
        loading: true,
        poll_ms: @default_poll_ms,
        poll_timer: nil
      )

    if connected?(socket) do
      {:ok, socket |> start_load() |> schedule_poll()}
    else
      {:ok, socket}
    end
  end

  # Re-poll FreightWare on the current interval.
  @impl true
  def handle_info(:poll, socket) do
    {:noreply, socket |> start_load() |> schedule_poll()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, start_load(socket)}

  # Live interval change from the header select.
  def handle_event("set_poll", %{"ms" => ms}, socket) do
    {:noreply, socket |> assign(poll_ms: String.to_integer(ms)) |> schedule_poll()}
  end

  @impl true
  def handle_async(:collections, {:ok, %{unauthorised: unauth, outstanding: out}}, socket) do
    unauthorised = unauth |> ok_list() |> by_date_desc()
    outstanding = out |> ok_list() |> by_date_desc()
    now = DateTime.utc_now()

    {first_seen, new_keys} =
      track_seen(socket.assigns.first_seen, unauthorised ++ outstanding, now)

    {:noreply,
     assign(socket,
       unauthorised: unauthorised,
       unauthorised_error: error(unauth),
       outstanding: outstanding,
       outstanding_error: error(out),
       first_seen: first_seen,
       new_keys: new_keys,
       now: now,
       updated_at: now,
       loading: false
     )}
  end

  def handle_async(:collections, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       loading: false,
       unauthorised_error: "load crashed (#{inspect(reason)})",
       outstanding_error: "load crashed"
     )}
  end

  defp start_load(socket) do
    socket
    |> assign(loading: true)
    |> start_async(:collections, fn ->
      %{
        unauthorised: Freight.unauthorised_collections(),
        outstanding: Freight.outstanding_collections()
      }
    end)
  end

  # (Re)arm the auto-refresh timer for the current interval, cancelling any pending
  # one first so an interval change takes effect immediately. `Off` (0) stops
  # auto-refresh — the manual ↻ button still works.
  defp schedule_poll(socket) do
    if ref = socket.assigns.poll_timer, do: Process.cancel_timer(ref)

    ref =
      case socket.assigns.poll_ms do
        ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :poll, ms)
        _ -> nil
      end

    assign(socket, poll_timer: ref)
  end

  defp poll_options, do: @poll_options

  defp poll_label(0), do: "auto-refresh off"
  defp poll_label(_), do: "live"

  defp ok_list({:ok, l}) when is_list(l), do: l
  defp ok_list(_), do: []

  # Newest first — by collection date, then collect-after time (ISO strings sort
  # lexically; blanks sort last).
  defp by_date_desc(rows),
    do: Enum.sort_by(rows, &{&1["collection_date"] || "", &1["collect_after"] || ""}, :desc)

  defp error({:ok, _}), do: nil
  defp error({:error, reason}), do: inspect(reason)
  defp error(_), do: nil

  # First-seen timestamp per collection, so we can show how long each has been
  # open. A first appearance is seeded from the collection's own date/time (real
  # age) when parseable, else now. `new_keys` are those that appeared since the
  # previous poll — flashed as "new" (never on the very first load).
  defp track_seen(prev, rows, now) do
    first_load? = map_size(prev) == 0

    first_seen =
      for c <- rows, into: %{} do
        k = key(c)
        {k, Map.get(prev, k) || seed_seen(c, now)}
      end

    new_keys =
      if first_load? do
        MapSet.new()
      else
        for c <- rows, k = key(c), not Map.has_key?(prev, k), into: MapSet.new(), do: k
      end

    {first_seen, new_keys}
  end

  defp key(c), do: c["collection_reference"] || c["collection_obj"] || :erlang.phash2(c)

  defp seed_seen(c, now) do
    case open_datetime(c) do
      %DateTime{} = dt -> if DateTime.compare(dt, now) == :lt, do: dt, else: now
      _ -> now
    end
  end

  defp open_datetime(c) do
    with d when is_binary(d) <- c["collection_date"],
         {:ok, date} <- Date.from_iso8601(d),
         time <- parse_time(c["collect_after"]),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp parse_time(t) when is_binary(t) do
    case Time.from_iso8601(t) do
      {:ok, time} -> time
      _ -> ~T[00:00:00]
    end
  end

  defp parse_time(_), do: ~T[00:00:00]

  defp age_seconds(c, first_seen, now) do
    case Map.get(first_seen, key(c)) do
      %DateTime{} = seen -> max(0, DateTime.diff(now, seen, :second))
      _ -> 0
    end
  end

  defp new?(c, new_keys, age), do: MapSet.member?(new_keys, key(c)) or age <= @new_within

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 lg:p-6 space-y-6 max-w-6xl mx-auto">
      <Layouts.app_nav active={:collections} />

      <header class="flex items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">Collections</h1>
          <p class="text-sm text-base-content/60">
            Awaiting authorisation and outstanding, for the current branch. Auto-refreshes every 10s
            during business hours (hourly overnight); rows are coloured by how long they've been open,
            and new ones flash.
          </p>
        </div>
        <div class="shrink-0 space-y-1 text-right">
          <div class="flex items-center justify-end gap-2">
            <span class="text-[11px] text-base-content/50">Auto-refresh</span>
            <form phx-change="set_poll">
              <select name="ms" class="select select-xs select-bordered">
                <option
                  :for={{label, ms} <- poll_options()}
                  value={ms}
                  selected={@poll_ms == ms}
                >
                  {label}
                </option>
              </select>
            </form>
            <button class="btn btn-sm btn-ghost" phx-click="refresh" disabled={@loading}>
              <span :if={@loading} class="loading loading-spinner loading-xs"></span> ↻ Refresh
            </button>
          </div>
          <div :if={@updated_at} class="text-[11px] text-base-content/50">
            {poll_label(@poll_ms)} · {duration(DateTime.diff(@now, @updated_at, :second))} ago
          </div>
        </div>
      </header>

      <.collections_section
        title="Awaiting authorisation"
        rows={@unauthorised}
        error={@unauthorised_error}
        loading={@loading}
        show_route={false}
        first_seen={@first_seen}
        new_keys={@new_keys}
        now={@now}
      />

      <.collections_section
        title="Outstanding (not yet manifested)"
        rows={@outstanding}
        error={@outstanding_error}
        loading={@loading}
        show_route={true}
        first_seen={@first_seen}
        new_keys={@new_keys}
        now={@now}
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :error, :string, default: nil
  attr :loading, :boolean, default: false
  attr :show_route, :boolean, default: false
  attr :first_seen, :map, required: true
  attr :new_keys, :any, required: true
  attr :now, :any, required: true

  defp collections_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <div class="flex items-center gap-2">
        <h2 class="text-lg font-semibold">{@title}</h2>
        <span class="badge badge-sm badge-outline">{length(@rows)}</span>
      </div>

      <div :if={@error} class="alert alert-error text-sm">Couldn't load: {@error}</div>

      <p
        :if={@rows == [] and is_nil(@error) and not @loading}
        class="text-sm text-base-content/50 py-4"
      >
        None.
      </p>

      <div :if={@rows != []} class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Open</th>
              <th>Reference</th>
              <th>Branch</th>
              <th>Date</th>
              <th>Window</th>
              <th>Consignor</th>
              <th>Consignee</th>
              <th :if={@show_route}>Route / Driver / Vehicle</th>
              <th class="text-right">Waybills</th>
              <th class="text-right">Parcels</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={c <- @rows}
              class={
                row_class(
                  age_seconds(c, @first_seen, @now),
                  new?(c, @new_keys, age_seconds(c, @first_seen, @now))
                )
              }
            >
              <% age = age_seconds(c, @first_seen, @now) %>
              <td class="whitespace-nowrap">
                <span :if={new?(c, @new_keys, age)} class="badge badge-xs badge-success mr-1">
                  NEW
                </span>
                <span class={"font-mono " <> age_class(age)}>{duration(age)}</span>
              </td>
              <td class="font-mono">{c["collection_reference"] || "—"}</td>
              <td>{c["originating_branch"] || "—"}</td>
              <td class="whitespace-nowrap">{c["collection_date"] || "—"}</td>
              <td class="whitespace-nowrap text-base-content/60">{window(c)}</td>
              <td>{party(c, "consignor")}</td>
              <td>{party(c, "consignee")}</td>
              <td :if={@show_route} class="text-base-content/60">{route(c)}</td>
              <td class="text-right font-mono">{c["estimated_waybills"] || "—"}</td>
              <td class="text-right font-mono">{c["estimated_parcels"] || "—"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp row_class(_age, true), do: "bg-success/10"
  defp row_class(age, _new) when age >= @red_after, do: "bg-error/5"
  defp row_class(_age, _new), do: ""

  defp age_class(age) when age >= @red_after, do: "text-error font-semibold"
  defp age_class(age) when age >= @amber_after, do: "text-warning"
  defp age_class(_age), do: "text-success"

  # Compact duration: 45s, 12m, 3h, 2d.
  defp duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp duration(_), do: "—"

  defp party(c, role) do
    [c["#{role}_name"], c["#{role}_city"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> nonempty()
  end

  defp window(c) do
    case {c["collect_after"], c["collect_before"]} do
      {nil, nil} -> "—"
      {a, nil} -> "from #{a}"
      {nil, b} -> "by #{b}"
      {a, b} -> "#{a}–#{b}"
    end
  end

  defp route(c) do
    [c["route_code"], c["driver_reference"], c["vehicle_registration"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
    |> nonempty()
  end

  defp nonempty(""), do: "—"
  defp nonempty(s), do: s
end
