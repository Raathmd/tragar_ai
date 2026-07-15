defmodule TragarAi.Freight.ColumnPrefs do
  @moduledoc """
  Shared, server-side persistence of the Collections dashboard column selection —
  the set of hidden column names.

  Unlike the browser's `localStorage` (which is per-browser), this is a single
  shared choice held in an ETS row, so opening the dashboard in a different
  browser (or after a refresh) restores the same columns. Writes are serialised
  through the GenServer and broadcast over PubSub so already-open LiveViews update
  live; reads hit ETS directly (no GenServer round-trip).

  The stored value is the *hidden* set, so an empty list is a valid state meaning
  "show every column". `set?/0` distinguishes "never chosen" from "chose to show
  all", which lets a fresh install seed the shared choice from the first browser's
  local selection.
  """
  use GenServer

  @table :collections_column_prefs
  @key :hidden
  @topic "collections:columns"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "PubSub topic broadcast on every change (`{:columns_changed, cols}`)."
  def topic, do: @topic

  @doc "The shared hidden-columns list (`[]` when unset or the store is down)."
  def get do
    case :ets.lookup(@table, @key) do
      [{@key, cols}] -> cols
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Whether a selection has ever been stored (vs. no choice made yet)."
  def set? do
    case :ets.lookup(@table, @key) do
      [{@key, _}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Store the hidden-columns list and broadcast the change to open dashboards."
  def put(cols) when is_list(cols), do: GenServer.call(__MODULE__, {:put, cols})

  @doc "Clear the stored selection (mainly for test isolation)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @impl true
  def handle_call({:put, cols}, _from, state) do
    :ets.insert(@table, {@key, cols})
    Phoenix.PubSub.broadcast(TragarAi.PubSub, @topic, {:columns_changed, cols})
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete(@table, @key)
    {:reply, :ok, state}
  end
end
