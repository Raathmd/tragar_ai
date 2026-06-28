defmodule TragarAi.QuoteIntake do
  @moduledoc """
  Quote-intake domain — guided quote creation driven from a Freshdesk ticket.

  A customer types what they want to ship into a Freshdesk ticket; Freshdesk
  POSTs each message to `/api/quotes/intake` (account in the body). This app
  carries the conversation, asking for the parameters FreightWare needs, and on
  confirmation creates/accepts the quote in FreightWare. State is kept per ticket
  in `Session` so the conversation survives across separate webhook calls.

  `Server` orchestrates; `Flow` holds the (pure, testable) question logic.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.QuoteIntake.Session do
      define :upsert_session, action: :upsert
      define :get_session, action: :read, get_by: [:ticket_id]
      define :list_sessions, action: :read
    end
  end

  @doc """
  The machine-readable quote workflow descriptor, enriched with the live
  FreightWare service types. Shared by the REST endpoint and the MCP tool.
  """
  def workflow do
    TragarAi.QuoteIntake.Flow.workflow(allowed_values: %{"service" => service_values()})
  end

  defp service_values do
    case TragarAi.Freight.service_types() do
      {:ok, types} when is_list(types) ->
        Enum.map(types, fn t ->
          %{
            "code" => t["code"],
            "label" => t["name"] || t["description"],
            "class" => t["service_class"]
          }
        end)

      _ ->
        []
    end
  end
end
