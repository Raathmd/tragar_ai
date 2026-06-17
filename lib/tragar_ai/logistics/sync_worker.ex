defmodule TragarAi.Logistics.SyncWorker do
  @moduledoc """
  Periodically refreshes the shipment cache from FreightWare.

  Runs every 15 minutes (see the Oban cron config). For each registered account
  it asks FreightWare for waybills updated within the look-back window and
  upserts them into the `Shipment` cache, so customer queries are served from
  Elixir rather than hitting FreightWare live.

  "Registered accounts" are `Account`s that are active and have at least one
  active `ApiClient` — there is no point syncing accounts nobody can query.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias TragarAi.Accounts
  alias TragarAi.Dovetail
  alias TragarAi.Logistics
  alias TragarAi.Tools.Normalize

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    window_minutes = Map.get(args, "window_minutes", default_window_minutes())
    updated_since = DateTime.add(DateTime.utc_now(), -window_minutes * 60, :second)

    accounts = registered_accounts()
    Logger.info("SyncWorker: refreshing #{length(accounts)} account(s) since #{updated_since}")

    Enum.each(accounts, fn account ->
      sync_account(account.account_reference, updated_since)
    end)

    :ok
  end

  @doc "Accounts that are active and have at least one active API client."
  def registered_accounts do
    with {:ok, accounts} <- Accounts.list_accounts(),
         {:ok, clients} <- Accounts.list_clients() do
      active_refs =
        clients
        |> Enum.filter(&(&1.status == :active and &1.scope == :account))
        |> MapSet.new(& &1.account_reference)

      Enum.filter(accounts, &(&1.active and MapSet.member?(active_refs, &1.account_reference)))
    else
      _ -> []
    end
  end

  defp sync_account(account_reference, updated_since) do
    params = %{
      "accountReference" => account_reference,
      "updatedSince" => DateTime.to_iso8601(updated_since)
    }

    case Dovetail.Client.list_waybills(params) do
      {:ok, data} ->
        data
        |> waybills()
        |> Enum.each(&upsert_waybill/1)

      {:error, reason} ->
        Logger.warning("SyncWorker: account #{account_reference} failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("SyncWorker: account #{account_reference} crashed: #{Exception.message(e)}")
  end

  # Upsert a waybill summary. We store what the list endpoint gave us; the
  # per-waybill tracking detail is filled in lazily on first track_shipment.
  defp upsert_waybill(waybill) when is_map(waybill) do
    number =
      waybill["waybillNumber"] || waybill["waybill_number"] || waybill["number"]

    if is_binary(number) do
      view = Normalize.waybill(number, waybill)

      Logistics.upsert_shipment(%{
        waybill_number: number,
        account_reference: view["account_reference"],
        service_type: view["service_type"],
        status_code: view["status_code"],
        status_description: view["status"],
        consignor_name: view["consignor"],
        consignee_name: view["consignee"],
        raw: waybill,
        view: view,
        tracked_at: DateTime.utc_now()
      })
    end
  end

  defp upsert_waybill(_), do: :ok

  defp waybills(%{"waybills" => list}) when is_list(list), do: list
  defp waybills(list) when is_list(list), do: list
  defp waybills(_), do: []

  defp default_window_minutes do
    :tragar_ai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:window_minutes, 20)
  end
end
