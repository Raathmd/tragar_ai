defmodule TragarAi.Assist.Validator do
  @moduledoc """
  The validate-before-act layer.

  Before any lookup, Elixir checks the model's structured request: is the intent
  one we allow, are the required entities present, and is the lookup permitted?
  The model only ever proposes a structured request — Elixir decides. This is
  what keeps the model an interpreter, never the authority on a fact.
  """

  # Required entities per intent. Intents with no required entity still must be
  # known to be allowed.
  @required %{
    load_status: [:waybill],
    eta: [:waybill],
    pod: [:waybill],
    waybill_lookup: [:waybill],
    route: [:waybill],
    invoice: [:account],
    ticket_context: [:ticket_id],
    stock: [],
    vehicle_status: []
  }

  @allowed Map.keys(@required)

  @doc "Allowed intents."
  def allowed_intents, do: @allowed

  @doc """
  Validate a structured request. Returns `:ok` or `{:error, reason}` where
  reason is `:not_understood`, `{:unknown_intent, intent}` or
  `{:missing_entities, [atom]}`.
  """
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{intent: :unknown}), do: {:error, :not_understood}

  def validate(%{intent: intent, entities: entities}) when intent in @allowed do
    case @required[intent] -- present_keys(entities) do
      [] -> :ok
      missing -> {:error, {:missing_entities, missing}}
    end
  end

  def validate(%{intent: intent}), do: {:error, {:unknown_intent, intent}}

  defp present_keys(entities) when is_map(entities) do
    for {k, v} <- entities, not is_nil(v) and v != "", do: k
  end

  defp present_keys(_), do: []
end
