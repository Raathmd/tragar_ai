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

  alias TragarAi.Assist.Actions

  @doc """
  The allowed actions for the model: read tools (Elixir executes) plus change
  actions (the agent performs in the source app). Each is tagged `action`.
  """
  @spec schema() :: [map()]
  def schema, do: read_tools() ++ change_tools()

  @doc """
  The read capability catalogue — one entry per allowed intent with its source,
  required entities and description. Used to build the interpret prompt so the
  model knows which source serves what (and can route a named source).
  """
  @spec catalog() :: [%{intent: atom(), source: String.t() | nil, required: [atom()], description: String.t()}]
  def catalog do
    for {intent, required} <- Validator.required() do
      %{
        intent: intent,
        source: source_name(intent),
        required: required,
        description: Map.get(@descriptions, intent, "")
      }
    end
  end

  defp read_tools do
    for {intent, required} <- Validator.required() do
      %{
        "name" => to_string(intent),
        "action" => "read",
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

  # Change actions aren't executed by the assistant — the agent does them in the
  # source app, then updates the ticket. Listed so the model knows what's possible.
  defp change_tools do
    for {entity, a} <- Actions.all() do
      %{
        "name" => "change_#{entity}",
        "action" => "change",
        "execution" => "performed_by_agent_in_source_app",
        "where" => a.where,
        "source" => "FreightWare",
        "source_functions" => a.functions,
        "description" =>
          "Change a #{entity} (#{a.verbs}). Not done by the assistant — the agent does it in " <>
            "#{a.where}, then returns and updates the ticket."
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
