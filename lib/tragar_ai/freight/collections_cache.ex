defmodule TragarAi.Freight.CollectionsCache do
  @moduledoc """
  Self-refreshing cache over the heavy FreightWare collections fetch.

  `/collections/outstanding` returns the branch's whole backlog (~8,700 rows, ~15s)
  which we trim to the recent window in-process — the API can't filter it server
  side. This GenServer fetches it ONCE on its own timer (every `@refresh_ms`), in
  the background, so the data stays current regardless of how many dashboards are
  open or how often they poll. Readers get the last result **instantly** via `get/0`;
  nobody triggers the heavy fetch just by viewing.

  So it's kept current by its own timer, not by the dashboard poll — the poll just
  reads the already-fresh cache. `refresh/0` forces an out-of-band refetch (the ↻).

  Temporary: swap the fetch for a filtered direct query once we can read the OpenEdge
  replica (then the whole ~15s all-rows pull disappears).
  """
  use GenServer

  require Logger

  alias TragarAi.Freight

  # How often we re-pull from FreightWare in the background.
  @refresh_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The latest cached `%{unauthorised: ..., outstanding: ...}` (each a `Freight`
  result tuple), served instantly. Returns empty lists until the first fetch lands.
  When the background poller is disabled (test), fetches live so callers still get
  real data.
  """
  def get do
    if enabled?(), do: GenServer.call(__MODULE__, :get), else: fetch()
  end

  defp enabled?, do: Application.get_env(:tragar_ai, __MODULE__, [])[:enabled] != false

  @doc "Force an out-of-band background refresh now (the manual ↻)."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(_) do
    # Skip the background poll in test (no live FreightWare); prod/dev refresh.
    if enabled?(), do: send(self(), :tick)
    {:ok, %{data: nil, refreshing?: false}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.data || %{unauthorised: {:ok, []}, outstanding: {:ok, []}}, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, kick(state)}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, kick(state)}
  end

  def handle_info({:refreshed, fresh}, state) do
    {:noreply, %{state | data: merge_good(state.data, fresh), refreshing?: false}}
  end

  # Keep the last good result per key when a refresh returns an error, so a
  # transient FreightWare 500/timeout doesn't blank the dashboard.
  defp merge_good(nil, fresh), do: fresh

  defp merge_good(old, fresh) do
    %{
      unauthorised: keep_good(old.unauthorised, fresh.unauthorised),
      outstanding: keep_good(old.outstanding, fresh.outstanding)
    }
  end

  defp keep_good(_old, {:ok, _} = fresh), do: fresh
  defp keep_good(old, _error), do: old

  # Fetch off the GenServer (it's ~15s) so get/0 stays instant; skip if one is
  # already in flight. Always reports back so `refreshing?` can't get stuck.
  defp kick(%{refreshing?: true} = state), do: state

  defp kick(state) do
    me = self()

    Task.start(fn ->
      data =
        try do
          fetch()
        rescue
          e ->
            Logger.error("[collections_cache] refresh crashed: #{inspect(e)}")
            %{unauthorised: {:error, :crashed}, outstanding: {:error, :crashed}}
        end

      send(me, {:refreshed, data})
    end)

    %{state | refreshing?: true}
  end

  defp fetch do
    %{
      unauthorised: Freight.unauthorised_collections(),
      outstanding: Freight.outstanding_collections()
    }
  end
end
