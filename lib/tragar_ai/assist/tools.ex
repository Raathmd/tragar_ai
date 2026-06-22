defmodule TragarAi.Assist.Tools do
  @moduledoc """
  The tool/function schema the Core AI interprets a question into.

  Derived from the **single source of truth** — `Validator.required/0` (allowed
  intents + their required entities) and the adapter registry (which source
  serves each). Handed to the local model in `:http` mode so it can only choose a
  valid call with typed arguments. The model *names* the call; Elixir still
  validates and executes it (the model never touches a source).
  """

  alias TragarAi.Adapters
  alias TragarAi.Assist.Validator

  @descriptions %{
    load_status: "Where a shipment is / its current status, by waybill.",
    eta: "Estimated arrival of a shipment, by waybill.",
    pod: "Proof of delivery for a shipment, by waybill.",
    waybill_lookup: "A waybill's details, by waybill.",
    track: "Tracking events for a shipment, by waybill.",
    route: "Planned / live route for a shipment, by waybill.",
    quote_lookup: "A freight quote, by quote number.",
    customer_lookup: "A customer / account, by account reference.",
    invoice: "An account's invoice / balance, by account reference.",
    ticket_context: "A support ticket's context, by ticket id.",
    service_types: "The service types Tragar offers.",
    stock: "Warehouse stock on hand.",
    vehicle_status: "A fleet vehicle's status / availability."
  }

  @entity_descriptions %{
    waybill: "Waybill / load number, e.g. 4821",
    account: "Account / debtor reference, e.g. ACC1001",
    quote: "Quote number, e.g. 7012",
    ticket_id: "Support ticket id, e.g. 55"
  }

  @doc "Function/tool definitions (JSON-schema-shaped) for every allowed intent."
  @spec schema() :: [map()]
  def schema do
    for {intent, required} <- Validator.required() do
      %{
        "name" => to_string(intent),
        "description" => Map.get(@descriptions, intent, ""),
        "source" => source_name(intent),
        "parameters" => %{
          "type" => "object",
          "properties" =>
            Map.new(required, fn entity ->
              {to_string(entity),
               %{"type" => "string", "description" => Map.get(@entity_descriptions, entity, "")}}
            end),
          "required" => Enum.map(required, &to_string/1)
        }
      }
    end
  end

  defp source_name(intent) do
    case Adapters.adapter_for(intent) do
      nil -> nil
      adapter -> adapter.name()
    end
  end
end
