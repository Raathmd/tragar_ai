defmodule TragarAi.Assist.Engine do
  @moduledoc """
  The Phase 1 safe loop:

      question → Core AI interprets → structured request
               → Elixir VALIDATES (allowed? exists? permitted?)
               → fetches the live fact (read-only)
               → Core AI phrases → draft answer → (agent reviews/edits/relays)

  Every call is persisted as a `TragarAi.Assist.Interaction` so the console has
  history and there is an audit trail. The agent always reviews before anything
  reaches a customer; on any failure the draft is a safe fallback the agent can
  replace.
  """

  alias TragarAi.Assist
  alias TragarAi.Assist.Validator
  alias TragarAi.Adapters
  alias TragarAi.CoreAI

  require Logger

  @doc """
  Run the loop for a question. `context` may carry `:agent` and `:entities`
  (structured fields the agent supplied, e.g. `%{waybill: "4821"}`), which take
  precedence over what the model extracted. Always returns `{:ok, interaction}`;
  the interaction's `status` reflects the outcome (`:drafted` or `:failed`).
  """
  @spec answer(String.t(), map()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def answer(question, context \\ %{}) when is_binary(question) do
    case CoreAI.interpret(question, context) do
      {:ok, request} ->
        entities = merge_entities(request.entities, context)
        process(question, %{request | entities: entities}, context)

      {:error, reason} ->
        Logger.warning("CoreAI.interpret failed: #{inspect(reason)}")

        fail(question, nil, %{}, context,
          error: "interpret_failed:#{inspect(reason)}",
          draft: "I couldn't interpret that question automatically — please answer it manually."
        )
    end
  end

  defp process(question, %{intent: intent, entities: entities}, context) do
    case Validator.validate(%{intent: intent, entities: entities}) do
      :ok -> fetch_and_phrase(question, intent, entities, context)
      {:error, reason} -> fail(question, intent, entities, context, validation_failure(reason))
    end
  end

  defp fetch_and_phrase(question, intent, entities, context) do
    case fetch_facts(intent, entities, context) do
      {:ok, facts} ->
        {:ok, draft} = CoreAI.phrase(intent, facts)

        create(%{
          question: question,
          intent: to_string(intent),
          entities: stringify(entities),
          facts: facts,
          source: source_name(intent),
          draft_answer: draft,
          status: :drafted,
          agent: context[:agent]
        })

      {:error, reason} ->
        fail(question, intent, entities, context, fetch_failure(reason, intent))
    end
  end

  # ── Failure handling — always a usable, safe interaction ────────────────────

  defp fail(question, intent, entities, context, error: error, draft: draft) do
    create(%{
      question: question,
      intent: intent && to_string(intent),
      entities: stringify(entities),
      source: intent && source_name(intent),
      draft_answer: draft,
      status: :failed,
      error: error,
      agent: context[:agent]
    })
  end

  defp validation_failure(:not_understood),
    do: [
      error: "not_understood",
      draft: "I couldn't tell what was being asked — please answer manually."
    ]

  defp validation_failure({:missing_entities, missing}),
    do: [
      error: "missing_entities:#{Enum.join(missing, ",")}",
      draft: "I need #{Enum.join(missing, ", ")} to answer that — please provide it."
    ]

  defp validation_failure({:unknown_intent, intent}),
    do: [error: "unknown_intent:#{intent}", draft: "That isn't something I can look up yet."]

  defp fetch_failure(:not_available, intent),
    do: [
      error: "not_available",
      draft: "The #{source_name(intent)} system isn't connected yet — please check it directly."
    ]

  defp fetch_failure(:missing_waybill, _),
    do: [error: "missing_waybill", draft: "I need a waybill number to look that up."]

  defp fetch_failure(:not_found, intent),
    do: [
      error: "not_found",
      draft: "I couldn't find that in #{source_name(intent)} — please check the number."
    ]

  defp fetch_failure(reason, intent),
    do: [
      error: inspect(reason),
      draft: "#{source_name(intent)} is temporarily unavailable — please try again shortly."
    ]

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # In demo mode, fact-check against fixtures; otherwise the live adapters.
  defp fetch_facts(intent, entities, %{demo: true}), do: TragarAi.Demo.fetch(intent, entities)
  defp fetch_facts(intent, entities, _context), do: Adapters.fetch(intent, entities)

  defp create(attrs), do: Assist.create_interaction(attrs)

  defp source_name(nil), do: nil

  defp source_name(intent) do
    case Adapters.adapter_for(intent) do
      nil -> nil
      source -> source.name()
    end
  end

  # Agent-supplied structured entities take precedence over the model's.
  defp merge_entities(model_entities, context) do
    Map.merge(model_entities || %{}, Map.get(context, :entities, %{}))
  end

  defp stringify(entities) when is_map(entities) do
    Map.new(entities, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify(_), do: %{}
end
