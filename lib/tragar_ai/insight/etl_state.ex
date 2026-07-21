defmodule TragarAi.Insight.EtlState do
  @moduledoc """
  Durable key → timestamp markers for the margin ETL.

  A minimal key/value store (`insight_etl_state`) for state the ETL must remember
  across runs — currently the `status_high_water` (how far
  `TragarAi.Insight.WaybillCostBackfill` has processed `fwt_status_history`
  change-events). Keep the surface tiny: `get_time/1` and `put_time/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TragarAi.Repo

  @type t :: %__MODULE__{}

  schema "insight_etl_state" do
    field :key, :string
    field :at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The stored timestamp for `key`, or `nil` if none."
  @spec get_time(String.t()) :: DateTime.t() | nil
  def get_time(key) do
    case Repo.get_by(__MODULE__, key: key) do
      %__MODULE__{at: at} -> at
      nil -> nil
    end
  end

  @doc "Upsert the timestamp for `key` (keyed on `:key`)."
  @spec put_time(String.t(), DateTime.t()) :: :ok
  def put_time(key, %DateTime{} = at) do
    %__MODULE__{}
    |> changeset(%{key: key, at: at})
    |> Repo.insert!(on_conflict: {:replace, [:at, :updated_at]}, conflict_target: :key)

    :ok
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:key, :at])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
