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
  alias TragarAi.Assist.Scope
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
    # Stamp the start so every persisted interaction records its loop latency.
    context = Map.put_new(context, :started_at, System.monotonic_time(:millisecond))

    case CoreAI.interpret(question, context) do
      {:ok, request} ->
        # The model may return several lookups; normalise each (agent entities +
        # carried conversation intent). A single request keeps the exact original
        # one-intent path; more than one runs the concurrent gather.
        requests =
          (Map.get(request, :intents) || [%{intent: request.intent, entities: request.entities}])
          |> Enum.map(fn r ->
            %{intent: effective_intent(r.intent, context), entities: merge_entities(r.entities, context)}
          end)
          |> Enum.uniq()

        case requests do
          [one] ->
            Logger.info(
              "[assist] interpret #{inspect(question)} -> #{one.intent} #{inspect(one.entities)}"
            )

            log = [interpret_entry(question, one.intent, one.entities)]
            process(question, %{intent: one.intent, entities: one.entities, raw: question}, context, log)

          many ->
            Logger.info(
              "[assist] interpret #{inspect(question)} -> multi #{inspect(Enum.map(many, & &1.intent))}"
            )

            process_many(question, many, context)
        end

      {:error, reason} ->
        Logger.warning("[assist] interpret failed: #{inspect(reason)}")

        log = [
          ai_entry(
            "CoreAI.interpret",
            %{"question" => question},
            %{"error" => inspect(reason)},
            false
          )
        ]

        if reasoning?(context) do
          reason_and_create(question, nil, %{}, context, {:interpret_failed, reason}, log)
        else
          fail(question, nil, %{}, context,
            error: "interpret_failed:#{inspect(reason)}",
            draft:
              "I couldn't interpret that question automatically — please answer it manually.",
            tool_log: log
          )
        end
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
        if out_of_scope?(facts, context) do
          scope_refused(question, intent, entities, context, log ++ [fetch_entry])
        else
          phrase_and_create(
            question,
            intent,
            entities,
            facts,
            source,
            context,
            log ++ [fetch_entry]
          )
        end

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

  # ── Multi-lookup (the model returned more than one intent) ───────────────────
  #
  # Validate each request, gather them CONCURRENTLY (emitting per-source progress
  # events), phrase EACH in-scope result, and persist one combined interaction.
  # Multiple lookups of the same source are kept (e.g. several waybills), since
  # results are a list, not keyed by intent.
  @gather_timeout 60_000

  defp process_many(question, requests, context) do
    interpret_entry = multi_interpret_entry(question, requests)
    valid = Enum.filter(requests, &(Validator.validate(&1) == :ok))

    case valid do
      [] ->
        # Nothing validatable — defer to the single-intent terminal handling for
        # the primary request (clarify / reason-freely), unchanged behaviour.
        first = hd(requests)
        clarify_fail(question, first.intent, first.entities, context, primary_reason(first), [
          interpret_entry
        ])

      _ ->
        {groups, fetch_entries} = gather(valid, context)

        case groups do
          [] ->
            first = hd(valid)

            fail(question, first.intent, first.entities, context,
              error: "no_facts",
              draft: "I couldn't retrieve those details right now — please try again shortly.",
              tool_log: [interpret_entry | fetch_entries]
            )

          _ ->
            {answered, phrase_entries} = phrase_groups(question, groups, context)
            create_combined(question, answered, context, [interpret_entry | fetch_entries] ++ phrase_entries)
        end
    end
  end

  # Concurrent fan-out. Each task emits {:source_started,…} / {:source_done,…} via
  # the optional `on_event` sink, so a live UI can show a per-source checklist as
  # lookups return. Returns the in-scope {:ok} results as groups, plus a tool_log
  # fetch entry for every attempt (ok/error) for the audit trail.
  defp gather(requests, context) do
    emit = event_sink(context)

    triples =
      requests
      |> Task.async_stream(
        fn r ->
          src = source_name(r.intent)
          emit.({:source_started, r.intent, src, r.entities})
          result = fetch_facts(r.intent, r.entities, context)
          emit.({:source_done, r.intent, src, r.entities, ok_result?(result, context)})
          {r, src, result}
        end,
        max_concurrency: max(length(requests), 1),
        ordered: true,
        timeout: @gather_timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(requests)
      |> Enum.map(fn
        {{:ok, triple}, _r} -> triple
        {{:exit, _reason}, r} -> {r, source_name(r.intent), {:error, :not_available}}
      end)

    fetch_entries =
      Enum.map(triples, fn {r, src, result} -> fetch_entry(src, r.intent, r.entities, result) end)

    groups =
      for {r, src, {:ok, facts}} <- triples, not out_of_scope?(facts, context) do
        %{intent: r.intent, source: src, entities: r.entities, facts: facts}
      end

    {groups, fetch_entries}
  end

  # Phrase each group in turn (sequential so the streamed answer stays coherent),
  # emitting a labelled header before each one so the combined answer is grouped.
  defp phrase_groups(question, groups, context) do
    on_chunk = context[:on_chunk]

    {answered, entries} =
      Enum.map_reduce(groups, [], fn g, acc ->
        if is_function(on_chunk, 1), do: on_chunk.(group_header(g))
        {:ok, answer} = CoreAI.phrase(g.intent, g.facts, %{question: question}, on_chunk)

        entry =
          ai_entry(
            "CoreAI.phrase",
            %{"intent" => to_string(g.intent), "source" => g.source, "entities" => stringify(g.entities)},
            %{"answer" => answer},
            true
          )

        {Map.put(g, :answer, answer), [entry | acc]}
      end)

    {answered, Enum.reverse(entries)}
  end

  defp create_combined(question, groups, context, tool_log) do
    draft = groups |> Enum.map(fn g -> "#{group_label(g)}\n#{g.answer}" end) |> Enum.join("\n\n")

    create(
      %{
        question: question,
        intent: groups |> Enum.map(&to_string(&1.intent)) |> Enum.uniq() |> Enum.join(", "),
        entities: groups |> Enum.flat_map(&Map.to_list(&1.entities)) |> Map.new() |> stringify(),
        facts: %{"results" => Enum.map(groups, &result_map/1)},
        source: groups |> Enum.map(& &1.source) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.join(", "),
        tool_log: tool_log,
        draft_answer: draft,
        status: :drafted,
        agent: context[:agent]
      },
      context
    )
  end

  defp result_map(g) do
    %{
      "intent" => to_string(g.intent),
      "source" => g.source,
      "entities" => stringify(g.entities),
      "facts" => g.facts,
      "answer" => g.answer
    }
  end

  defp multi_interpret_entry(question, requests) do
    ai_entry(
      "CoreAI.interpret",
      %{"question" => question},
      %{
        "intents" =>
          Enum.map(requests, fn r ->
            %{"intent" => to_string(r.intent), "entities" => stringify(r.entities)}
          end)
      },
      true
    )
  end

  # A short "Source · intent (entity)" label for grouping the combined answer.
  defp group_header(g), do: "\n\n#{group_label(g)}\n"

  defp group_label(g) do
    base = "#{g.source || "Source"} · #{g.intent}"
    case primary_entity_value(g.entities) do
      nil -> base
      v -> "#{base} (#{v})"
    end
  end

  defp primary_entity_value(entities) when is_map(entities),
    do: entities[:waybill] || entities[:quote] || entities[:account] || entities[:ticket_id]

  defp primary_entity_value(_), do: nil

  defp ok_result?({:ok, facts}, context), do: not out_of_scope?(facts, context)
  defp ok_result?(_, _), do: false

  defp event_sink(context) do
    case context[:on_event] do
      f when is_function(f, 1) -> f
      _ -> fn _ -> :ok end
    end
  end

  defp primary_reason(request) do
    case Validator.validate(request) do
      {:error, reason} -> reason
      :ok -> :not_understood
    end
  end

  # Refuse facts outside the validated account scope (only when one is supplied;
  # the trusted console passes no `:accounts` and is unrestricted).
  defp out_of_scope?(facts, context) do
    case context[:accounts] do
      accounts when is_list(accounts) and accounts != [] -> not Scope.within?(facts, accounts)
      _ -> false
    end
  end

  defp scope_refused(question, intent, entities, context, log) do
    fail(
      question,
      intent,
      entities,
      context,
      error: "out_of_scope",
      draft:
        "That record isn't on the requester's account, so I can't share its details. " <>
          "Please confirm the reference with the customer.",
      tool_log: log
    )
  end

  # `log` already includes the fetch entry. Phrase answers the original question
  # from the facts (e.g. amendability from a status), so the model interprets the
  # facts, not just restates them.
  defp phrase_and_create(question, intent, entities, facts, source, context, log) do
    # `on_chunk` (set only by the live UIs) streams the answer; ticket/quote
    # callers don't pass it, so they get the full answer in one shot.
    {:ok, draft} = CoreAI.phrase(intent, facts, %{question: question}, context[:on_chunk])
    Logger.info("[assist] phrase #{intent} -> #{inspect(draft)}")

    phrase_entry =
      ai_entry("CoreAI.phrase", %{"intent" => to_string(intent)}, %{"answer" => draft}, true)

    create(
      %{
        question: question,
        intent: to_string(intent),
        entities: stringify(entities),
        facts: facts,
        source: source,
        tool_log: log ++ [phrase_entry],
        draft_answer: draft,
        status: :drafted,
        agent: context[:agent]
      },
      context
    )
  end

  # No grounded fact was produced (unmatched, or the lookup returned nothing).
  # By default the AI prompts the user back; in "reason freely" mode it instead
  # reasons over the question directly rather than short-circuiting.
  defp clarify_fail(question, intent, entities, context, reason, log) do
    if reasoning?(context) do
      reason_and_create(question, intent, entities, context, reason, log)
    else
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
  end

  # Ungrounded answer from the model — clearly marked `:reasoned`, no facts. Never
  # reached for a scope refusal (that path stays a hard fail), so reasoning can't
  # leak account-scoped data.
  defp reason_and_create(question, intent, entities, context, reason, log) do
    {:ok, answer} = CoreAI.reason(question, context, context[:on_chunk])
    Logger.info("[assist] reason #{inspect(reason)} -> #{inspect(answer)}")

    entry =
      ai_entry("CoreAI.reason", %{"after" => inspect(reason)}, %{"answer" => answer}, true)

    create(
      %{
        question: question,
        intent: intent && to_string(intent),
        entities: stringify(entities),
        source: "reasoning",
        tool_log: log ++ [entry],
        draft_answer: answer,
        status: :reasoned,
        agent: context[:agent]
      },
      context
    )
  end

  defp reasoning?(context), do: context[:free_reasoning] == true

  defp error_code(:not_understood), do: "not_understood"
  defp error_code(:not_found), do: "not_found"
  defp error_code(:missing_waybill), do: "missing_waybill"
  defp error_code({:missing_entities, missing}), do: "missing_entities:#{Enum.join(missing, ",")}"
  defp error_code({:unknown_intent, intent}), do: "unknown_intent:#{intent}"
  defp error_code(other), do: inspect(other)

  # In demo mode, fact-check against fixtures; otherwise the live adapters.
  # A misconfigured/unreachable source (e.g. missing Dovetail credentials) raises
  # or exits deep in an adapter/GenServer; catch it here so a single source being
  # down degrades to a graceful "not connected" reply instead of crashing the turn.
  defp fetch_facts(intent, entities, %{demo: true}),
    do: safe_fetch(fn -> TragarAi.Demo.fetch(intent, entities) end, intent)

  defp fetch_facts(intent, entities, _context),
    do: safe_fetch(fn -> Adapters.fetch(intent, entities) end, intent)

  defp safe_fetch(fun, intent) do
    fun.()
  rescue
    e ->
      Logger.error("[assist] source #{inspect(intent)} raised: #{Exception.message(e)}")
      {:error, :not_available}
  catch
    :exit, reason ->
      Logger.error("[assist] source #{inspect(intent)} exited: #{inspect(reason)}")
      {:error, :not_available}
  end

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
    create(
      %{
        question: question,
        intent: intent && to_string(intent),
        entities: stringify(entities),
        source: intent && source_name(intent),
        tool_log: opts[:tool_log] || [],
        draft_answer: opts[:draft],
        status: :failed,
        error: opts[:error],
        agent: context[:agent]
      },
      context
    )
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

  # Persist, stamping the ticket (for grouping on the dashboard) and the loop
  # latency (request → response) from the context.
  defp create(attrs, context) do
    result =
      attrs
      |> Map.put(:ticket_id, context[:ticket_id])
      |> Map.put(:duration_ms, elapsed_ms(context))
      |> Assist.create_interaction()

    # Push the live monitor; harmless when there are no subscribers.
    with {:ok, _} <- result, do: TragarAi.Dashboard.broadcast()
    result
  end

  defp elapsed_ms(%{started_at: t}) when is_integer(t),
    do: System.monotonic_time(:millisecond) - t

  defp elapsed_ms(_), do: nil

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

  # In a conversation, a turn that only supplies an entity keeps the prior intent.
  defp effective_intent(:unknown, context), do: Map.get(context, :intent) || :unknown
  defp effective_intent(intent, _context), do: intent

  defp stringify(entities) when is_map(entities) do
    Map.new(entities, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify(_), do: %{}
end
