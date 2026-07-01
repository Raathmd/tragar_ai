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

  @doc """
  Drive a guided quote from the console or chat. `session_id` scopes the
  conversation (a stable per-conversation id), `opts[:account]` is the resolved
  FreightWare account, and `message` is the customer's latest input — `""` opens
  the conversation with the first question.

  Returns the same result map as the Freshdesk intake — `reply`, `slot`,
  `options` (clickable choices for the current slot), `status`, and, once ready
  or created, `rate` / `quote_number`. Unlike the Freshdesk path this NEVER posts
  to a ticket; it only reads and (on ACCEPT) creates a quote in FreightWare.
  """
  def converse(session_id, message, opts \\ []) when is_binary(session_id) do
    TragarAi.QuoteIntake.Server.handle(
      %{ticket_id: session_id, message: message, account: opts[:account]},
      Keyword.take(opts, [:freightware, :freshdesk])
    )
  end

  @doc """
  Clickable options for the `service` slot — the live FreightWare service types as
  `[%{value, label}]`. Supplied by the UI (kept out of the Server so its result
  stays free of live API calls). Empty when service types can't be fetched.
  """
  def service_options do
    case TragarAi.Freight.service_types() do
      {:ok, types} when is_list(types) ->
        Enum.map(types, fn t ->
          name = t["name"] || t["description"] || t["code"]
          %{value: name, label: name}
        end)

      _ ->
        []
    end
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
