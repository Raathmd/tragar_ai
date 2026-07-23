defmodule TragarAi.Repo.Migrations.CreateInsightManifestOrigin do
  use Ecto.Migration

  # Materialised delivery-manifest origin per waybill. The only link from a waybill
  # to its delivery manifest is through the FreightWare parcel tables
  # (waybill -> fwt_waybill_parcel -> fwt_parcel_tripsheet -> fwt_tripsheet), which
  # is a huge, unindexed scan — too slow to resolve live. So we resolve it ONCE,
  # offline, in ManifestOriginBackfill (via ManifestOriginWorker) and store the
  # supplier's collection depot (the tripsheet station) plus the fields a quick
  # quote needs, so the /_inspect quote form fills instantly and the margin expected
  # cost can eventually price on the correct manifest-station origin.
  def change do
    create table(:insight_manifest_origin) do
      add :waybill_number, :string, null: false
      # Delivery supplier (the tripsheet's station_contractor) — the quote account.
      add :contractor_reference, :string

      # Origin = the delivery-manifest (tripsheet) station: its site + address.
      add :origin_site, :string
      add :origin_suburb, :string
      add :origin_city, :string
      add :origin_postcode, :string

      # Destination = the waybill's consignee.
      add :consignee_suburb, :string
      add :consignee_city, :string
      add :consignee_postcode, :string

      # The waybill's chargeable weight and its actual FRA (freight) charge, so a
      # quote's freightCharge can be compared to the actual.
      add :weight, :decimal
      add :actual_fra, :decimal

      timestamps(type: :utc_datetime)
    end

    create unique_index(:insight_manifest_origin, [:waybill_number])
    create index(:insight_manifest_origin, [:contractor_reference])
  end
end
