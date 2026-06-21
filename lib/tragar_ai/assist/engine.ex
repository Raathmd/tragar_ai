defmodule TragarAi.Assist.Engine do
  @moduledoc """
  The Phase 1 safe loop:

      question → Core AI interprets → structured request
               → Elixir VALIDATES (allowed? exists? permitted?)
               → fetches the live fact (read-only)
               → Core AI phrases → draft answer → (agent reviews/edits/relays)

  Every call is persisted as a `TragarAi.Assist.Interaction` — including a
  `tool_log` of each AI and source/tool call made (with params and returned
  data) — so the console has history, a visible trace, and an audit trail.
  """

  alias TragarAi.Assist
  alias TragarAi.Assist.Validator
  alias TragarAi.Adapters
  alias TragarAi.CoreAI

  require Logger

  @doc """
  Run the loop for a question. `context` may carry `:agent`, `:entities`
  (structured fields the agent supplied), and `:demo` (fetch from fixtures).
  Always returns `{:ok, interaction}`.
  """
  @spec answer(String.t(), map()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def answer(question, context \\ %{}) when is_binary(question) do
    case CoreAI.interpret(question, context) do
      {:ok, request} ->
        entities = merge_entities(request.entities, context)

        Logger.info(
          "[assist] interpret #{inspect(question)} -> #{request.intent} #{inspect(entities)}"
        )

        log = [interpret_entry(question, request.intent, entities)]
        process(question, %{request | entities: entities}, context, log)

      {:error, reason} ->
        Logger.warning("[assist] interpret failed: #{inspect(reason)}")

        fail(question, nil, %{}, context,
          error: "interpret_failed:#{inspect(reason)}",
          draft: "I couldn't interpret that question automatically — please answer it manually.",
          tool_log: [
            ai_entry(
              "CoreAI.interpret",
              %{"question" => question},
              %{"error" => inspect(reason)},
              false
            )
          ]
        )
    end
  end

  defp process(question, %{intent: intent, entities: entities}, context, log) do
    case Validator.validate(%{intent: intent, entities: entities}) do
      :ok ->
        fetch_and_phrase(question, intent, entities, context, log)

      {:error, reason} ->
        # Intent/entity doesn't match Tragar — the AI prompts the user back.
        clarify_fail(question, intent, entities, context, reason, log)
    end
  end

  defp fetch_and_phrase(question, intent, entities, context, log) do
    source = source_name(intent)
    result = fetch_facts(intent, entities, context)

    Logger.info(
      "[assist] source call #{source}.#{intent} #{inspect(entities)} -> #{summarise(result)}"
    )

    fetch_entry = fetch_entry(source, intent, entities, result)

    case result do
      {:ok, facts} ->
        {:ok, draft} = CoreAI.phrase(intent, facts)
        Logger.info("[assist] phrase #{intent} -> #{inspect(draft)}")

        phrase_entry =
          ai_entry("CoreAI.phrase", %{"intent" => to_string(intent)}, %{"answer" => draft}, true)

        create(%{
          question: question,
          intent: to_string(intent),
          entities: stringify(entities),
          facts: facts,
          source: source,
          tool_log: log ++ [fetch_entry, phrase_entry],
          draft_answer: draft,
          status: :drafted,
          agent: context[:agent]
        })

      {:error, reason} when reason in [:not_found, :missing_waybill] ->
        # Reference isn't an entity in Tragar — prompt back for a valid one.
        clarify_fail(question, intent, entities, context, reason, log ++ [fetch_entry])

      {:error, reason} ->
        fail(
          question,
          intent,
          entities,
          context,
          fetch_failure(reason, intent) ++ [tool_log: log ++ [fetch_entry]]
        )
    end
  end

  # The AI asks the user for what it needs (logged as a CoreAI.clarify call).
  defp clarify_fail(question, intent, entities, context, reason, log) do
    {:ok, prompt} = CoreAI.clarify(reason)
    Logger.info("[assist] clarify #{inspect(reason)} -> #{inspect(prompt)}")

    entry =
      ai_entry("CoreAI.clarify", %{"reason" => inspect(reason)}, %{"prompt" => prompt}, true)

    fail(question, intent, entities, context,
      error: error_code(reason),
      draft: prompt,
      tool_log: log ++ [entry]
    )
  end

  defp error_code(:not_understood), do: "not_understood"
  defp error_code(:not_found), do: "not_found"
  defp error_code(:missing_waybill), do: "missing_waybill"
  defp error_code({:missing_entities, missing}), do: "missing_entities:#{Enum.join(missing, ",")}"
  defp error_code({:unknown_intent, intent}), do: "unknown_intent:#{intent}"
  defp error_code(other), do: inspect(other)

  # In demo mode, fact-check against fixtures; otherwise the live adapters.
  defp fetch_facts(intent, entities, %{demo: true}), do: TragarAi.Demo.fetch(intent, entities)
  defp fetch_facts(intent, entities, _context), do: Adapters.fetch(intent, entities)

  # ── tool_log entries ─────────────────────────────────────────────────────────

  defp interpret_entry(question, intent, entities) do
    ai_entry(
      "CoreAI.interpret",
      %{"question" => question},
      %{"intent" => to_string(intent), "entities" => stringify(entities)},
      true
    )
  end

  defp ai_entry(tool, params, result, ok?),
    do: %{"kind" => "ai", "tool" => tool, "params" => params, "result" => result, "ok" => ok?}

  defp fetch_entry(source, intent, entities, {:ok, facts}),
    do: %{
      "kind" => "source",
      "tool" => "#{source}.#{intent}",
      "params" => stringify(entities),
      "result" => facts,
      "ok" => true
    }

  defp fetch_entry(source, intent, entities, {:error, reason}),
    do: %{
      "kind" => "source",
      "tool" => "#{source}.#{intent}",
      "params" => stringify(entities),
      "result" => %{"error" => inspect(reason)},
      "ok" => false
    }

  defp summarise({:ok, facts}) when is_map(facts), do: "#{map_size(facts)} fields"
  defp summarise({:error, reason}), do: "error #{inspect(reason)}"
  defp summarise(other), do: inspect(other)

  # ── Failure handling — always a usable, safe interaction ────────────────────

  defp fail(question, intent, entities, context, opts) do
    create(%{
      question: question,
      intent: intent && to_string(intent),
      entities: stringify(entities),
      source: intent && source_name(intent),
      tool_log: opts[:tool_log] || [],
      draft_answer: opts[:draft],
      status: :failed,
      error: opts[:error],
      agent: context[:agent]
    })
  end

  defp fetch_failure(:not_available, intent),
    do: [
      error: "not_available",
      draft: "The #{source_name(intent)} system isn't connected yet — please check it directly."
    ]

  defp fetch_failure(reason, intent),
    do: [
      error: inspect(reason),
      draft: "#{source_name(intent)} is temporarily unavailable — please try again shortly."
    ]

  # ── Helpers ─────────────────────────────────────────────────────────────────

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
