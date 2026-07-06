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
  alias TragarAi.Assist.Entities
  alias TragarAi.Assist.Scope
  alias TragarAi.Assist.Validator
  alias TragarAi.Adapters
  alias TragarAi.CoreAI
  alias TragarAi.Freight.Accounts
  alias TragarAi.Harmonize
  alias TragarAi.QuoteIntake.Flow

  require Logger

  @doc """
  Run the loop for a question. `context` may carry `:agent` and `:entities`
  (structured fields the agent supplied). Always returns `{:ok, interaction}`.
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
          (Map.get(request, :intents) ||
             [
               %{
                 intent: request.intent,
                 entities: request.entities,
                 scope: Map.get(request, :scope, "one")
               }
             ])
          |> Enum.map(fn r ->
            %{
              intent: effective_intent(r.intent, context),
              entities: merge_entities(r.entities, context),
              scope: Map.get(r, :scope, "one")
            }
          end)
          |> Enum.uniq()

        refs = reference_values(requests)

        cond do
          # A request to be quoted / priced for a NEW shipment. This isn't a read
          # of an existing record — it's the entry to the guided quote flow — so it
          # never touches the read fan-out. We recognise it and pull out whatever
          # the message already stated, rather than dead-ending on "which quote?".
          Enum.any?(requests, &(&1.intent == :quick_quote)) ->
            Logger.info("[assist] quick_quote <- #{inspect(question)}")
            process_quick_quote(question, context)

          # A reference number in the request → don't trust the model's single
          # guess. Test it against EVERY reference endpoint across all sources
          # (broad), then frame the answer from all discovered facts.
          refs != [] ->
            Logger.info("[assist] reference surface #{inspect(refs)} <- #{inspect(question)}")
            process_reference(question, refs, context)

          # Non-reference single request (account/ticket/vehicle/service): keep the
          # existing narrow-or-broad handling (account soft-gate, source-specific
          # errors); only a broad request fans out.
          match?([_], requests) ->
            one = hd(requests)

            if narrow?(one) do
              log = [interpret_entry(question, one.intent, one.entities)]

              process(
                question,
                %{intent: one.intent, entities: one.entities, raw: question},
                context,
                log
              )
            else
              process_surface(question, expand_request(one), context)
            end

          true ->
            Logger.info(
              "[assist] interpret #{inspect(question)} -> surface #{inspect(Enum.map(requests, &{&1.intent, &1.scope}))}"
            )

            process_surface(question, expand_requests(requests), context)
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

  # Recognise a "price this shipment" request and surface what the message already
  # told us, plus what the guided quote still needs, as a drafted answer. Pricing +
  # creation is the stateful `QuoteIntake` flow (quick_quote → accept → FreightWare
  # quote); this is the assist-loop front door that names it instead of failing.
  defp process_quick_quote(question, context) do
    # The model reads whatever the customer already stated; Elixir lists what the
    # guided quote still needs. Extraction is best-effort — anything missing is
    # simply asked for.
    {:ok, seed} = CoreAI.quote_extract(question)

    known =
      Flow.slot_keys()
      |> Enum.flat_map(fn key -> if v = seed[key], do: ["#{key}: #{v}"], else: [] end)

    needed = Enum.reject(Flow.slot_keys(), &Map.has_key?(seed, &1))
    understood = if known == [], do: "", else: " So far I've got — #{Enum.join(known, "; ")}."

    draft =
      "That's a request for a delivery price — I can put it through a quick quote." <>
        understood <>
        " To rate it in FreightWare I still need: #{Enum.join(needed, ", ")}. " <>
        "Start a guided quote to price it (and create it on FreightWare if accepted)."

    create(
      %{
        question: question,
        intent: "quick_quote",
        entities: %{},
        facts: %{"seed" => seed, "needed" => needed},
        source: "FreightWare",
        tool_log: [interpret_entry(question, :quick_quote, %{})],
        draft_answer: draft,
        status: :drafted,
        agent: context[:agent]
      },
      context
    )
  end

  defp process(question, %{intent: intent, entities: entities}, context, log) do
    case Validator.validate(%{intent: intent, entities: entities}) do
      :ok ->
        case resolve_account(intent, entities, context) do
          {:ok, entities} ->
            fetch_and_phrase(question, intent, entities, context, log)

          {:ask, message} ->
            # Never a hard stop when a user is prompting — ask for/confirm the
            # account instead of rejecting the request.
            ask_for_account(question, intent, entities, context, message, log)
        end

      {:error, reason} ->
        # Intent/entity doesn't match Tragar — the AI prompts the user back.
        clarify_fail(question, intent, entities, context, reason, log)
    end
  end

  # Soft account handling. Returns `{:ok, entities}` (account resolved/valid, or
  # dropped when not needed) or `{:ask, message}` to prompt the user — never a
  # hard failure. A Freshdesk-derived scope (`context.accounts`) is authoritative
  # and trusted as-is.
  defp resolve_account(intent, entities, context) do
    requires? = :account in Map.get(Validator.required(), intent, [])
    account = entities[:account]

    cond do
      is_list(context[:accounts]) and context[:accounts] != [] ->
        {:ok, entities}

      is_binary(account) and account != "" ->
        if Accounts.valid?(account) do
          {:ok, entities}
        else
          # A model-guessed code may be wrong, or actually a company name — try to
          # resolve it before giving up.
          case Accounts.resolve(%{code: account, company: account}) do
            {:ok, ref} ->
              {:ok, Map.put(entities, :account, ref)}

            {:ambiguous, refs} ->
              {:ask, ambiguity_message(refs)}

            :none ->
              if requires?,
                do: {:ask, need_account_message()},
                else: {:ok, Map.delete(entities, :account)}
          end
        end

      requires? ->
        {:ask, need_account_message()}

      true ->
        {:ok, entities}
    end
  end

  defp ask_for_account(question, intent, entities, context, message, log) do
    fail(question, intent, entities, context,
      error: "account_needed",
      draft: message,
      tool_log: log
    )
  end

  defp need_account_message,
    do:
      "To look that up I need the FreightWare account code — please include it in your prompt " <>
        "(e.g. \"invoices for ITD02\")."

  defp ambiguity_message(refs),
    do:
      "A few accounts match — which one did you mean? #{Enum.join(refs, ", ")}. " <>
        "Add the code to your prompt."

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

  # The reference slots a bare number can be tested against, and the shipment
  # entities to probe each value across — a bare id is a waybill or a quote, so
  # this fans out over load_status/track/route (FreightWare + Vantage) AND
  # quote_lookup. (Account/vehicle/ticket are typed differently, not bare ids.)
  @ref_slots [:waybill, :quote]
  @probe_entities [:waybill, :quote]

  # A request is narrow when the model asked for one fact or the entity has no
  # domain capability group to fan out over.
  defp narrow?(%{scope: scope, entities: entities}),
    do: scope == "one" or is_nil(Entities.entity_for(entities))

  # Every bare reference number the model extracted (from any request).
  defp reference_values(requests) do
    for(r <- requests, slot <- @ref_slots, v = r.entities[slot], is_binary(v) and v != "", do: v)
    |> Enum.uniq()
  end

  # Test each reference value against EVERY reference capability across all
  # sources — is it a waybill? a quote? — so the answer is framed from whatever
  # any source knows about it, not the model's single guess.
  defp expand_probe(values) do
    for(
      value <- values,
      entity <- @probe_entities,
      %{param: param, capabilities: caps} = Entities.group(entity),
      cap <- caps,
      do: sub(cap, %{param => value}, entity, value)
    )
    |> Enum.uniq()
  end

  # The capability whose phrasing best represents an entity's harmonised record.
  @canonical_intent %{
    waybill: :load_status,
    account: :customer_lookup,
    quote: :quote_lookup,
    ticket: :ticket_context,
    vehicle: :vehicle_status
  }

  defp phrasing_intent(entity, slices) do
    intents = Enum.map(slices, & &1.intent)
    canon = Map.get(@canonical_intent, entity)
    if canon in intents, do: canon, else: hd(intents)
  end

  # Expand a request into the concrete sub-lookups to gather. Broad + grouped →
  # one sub-request per capability in the entity's group; otherwise the single
  # lookup. Each sub-request is tagged with its domain entity + reference key so
  # the gathered slices can be grouped and harmonised per entity.
  defp expand_request(%{intent: intent, entities: entities, scope: scope}) do
    case Entities.entity_for(entities) do
      nil ->
        [sub(intent, entities, nil, to_string(intent))]

      entity ->
        key = Entities.key(entity, entities)

        if scope == "one" do
          [sub(intent, entities, entity, key)]
        else
          for cap <- Entities.group(entity).capabilities, do: sub(cap, entities, entity, key)
        end
    end
  end

  defp sub(intent, entities, entity, key),
    do: %{intent: intent, entities: entities, entity: entity, entity_key: key}

  # Expand a SET of requests, collapsing same-entity requests into the entity's
  # full cross-source capability group when that entity is asked about more than
  # once OR any request for it is broad. So "status AND eta AND pod for X" (three
  # FreightWare facets) surfaces EVERY source for X — including Vantage's route —
  # and one source's miss never suppresses the others.
  defp expand_requests(requests) do
    {grouped, ungrouped} =
      Enum.split_with(requests, fn r -> Entities.entity_for(r.entities) != nil end)

    entity_subs =
      grouped
      |> Enum.group_by(fn r ->
        entity = Entities.entity_for(r.entities)
        {entity, Entities.key(entity, r.entities)}
      end)
      |> Enum.flat_map(fn {{entity, key}, reqs} ->
        broad? = length(reqs) > 1 or Enum.any?(reqs, &(&1.scope == "all"))
        entities = hd(reqs).entities

        if broad? do
          for cap <- Entities.group(entity).capabilities, do: sub(cap, entities, entity, key)
        else
          for r <- reqs, do: sub(r.intent, r.entities, entity, key)
        end
      end)

    entity_subs ++ Enum.flat_map(ungrouped, &expand_request/1)
  end

  # Validate the sub-lookups, gather them concurrently, harmonise the slices per
  # domain entity, phrase one answer per entity, and persist a single interaction.
  # Probe reference values across every reference endpoint; harmonise + frame from
  # all discovered facts, or prompt back when the reference is nowhere to be found.
  defp process_reference(question, values, context) do
    subs = expand_probe(values)
    interpret_entry = multi_interpret_entry(question, subs)
    valid = Enum.filter(subs, &(Validator.validate(&1) == :ok))
    {groups, fetch_entries} = gather(valid, context)
    log = [interpret_entry | fetch_entries]

    # The value matched a waybill/quote NUMBER → surface it. Otherwise fall back to
    # testing the SAME value as the customer's own shipperReference (account-scoped).
    if groups != [] do
      surface_reference(question, groups, context, log)
    else
      case resolve_by_shipper_reference(values, context) do
        {:matches, [_ | _] = ref_groups, ref_entries} ->
          surface_reference(question, ref_groups, context, log ++ ref_entries)

        {:matches, [], ref_entries} ->
          unscoped_reference_fail(question, values, context, log ++ ref_entries)

        {:need_account, :ambiguous, accounts} ->
          confirm_account_fail(question, values, context, accounts, log)

        {:need_account, :none, _} ->
          unscoped_reference_fail(question, values, context, log)
      end
    end
  end

  defp surface_reference(question, groups, context, log) do
    {results, phrase_entries} = harmonize_and_phrase(question, groups, context)
    create_surface(question, results, context, log ++ phrase_entries)
  end

  # The identifier couldn't be scoped to any entity in any source — say what we
  # tried and, since a bare value may be the customer's own reference, nudge for
  # the account that would let the shipperReference search run.
  defp unscoped_reference_fail(question, values, context, log) do
    ref = hd(values)

    fail(question, :load_status, %{waybill: ref}, context,
      error: "unscoped_reference:#{ref}",
      draft:
        "I couldn't match \"#{ref}\" to a waybill or quote in FreightWare or Vantage. " <>
          "If it's the customer's own reference, include the FreightWare account " <>
          "(e.g. \"for ITD02\") so I can search on it — otherwise let me know what it refers to.",
      tool_log: log
    )
  end

  # A Freshdesk ticket entitled to several accounts can't run a reference search
  # without picking one (that would cross accounts) — ask the agent to confirm.
  defp confirm_account_fail(question, values, context, accounts, log) do
    ref = hd(values)

    fail(question, :load_status, %{waybill: ref}, context,
      error: "account_ambiguous",
      draft:
        "To look up \"#{ref}\" I need to confirm the account — this request is linked to " <>
          "#{Enum.join(accounts, ", ")}. Which account does it belong to?",
      tool_log: log
    )
  end

  # Cap the shipper-reference fan-out: one reference can map to many waybills, and
  # each match is fetched in full — bound the concurrent lookups.
  @ref_match_limit 10

  # Search FreightWare for each value as a shipper reference, resolving it to
  # EVERY matching waybill. The search is bound to a SINGLE account (never spans
  # accounts) — a Freshdesk ticket entitled to several must confirm which one, so
  # a search can't cross accounts. Returns:
  #   {:matches, groups, tool_entries} — one group per matched waybill, or
  #   {:need_account, :ambiguous, accounts} / {:need_account, :none} — no search ran.
  defp resolve_by_shipper_reference(values, context) do
    case search_account(context) do
      {:ok, account} ->
        {numbers, search_entries} = shipper_ref_numbers(values, account)
        subs = for n <- Enum.take(numbers, @ref_match_limit), do: waybill_sub(n)
        {groups, fetch_entries} = gather(subs, context)
        {:matches, groups, search_entries ++ fetch_entries}

      :ambiguous ->
        {:need_account, :ambiguous, context[:accounts]}

      :none ->
        {:need_account, :none, []}
    end
  end

  # The one account a reference search may run against: a Freshdesk scope of
  # exactly one entitled account, or the single account supplied in the prompt.
  # Several entitled accounts is ambiguous (must be confirmed); none is unscoped.
  defp search_account(context) do
    case context[:accounts] do
      [account] when is_binary(account) and account != "" -> {:ok, account}
      [_, _ | _] -> :ambiguous
      _ -> supplied_account(context)
    end
  end

  defp supplied_account(context) do
    case get_in(context, [:entities, :account]) do
      account when is_binary(account) and account != "" ->
        if Accounts.valid?(account), do: {:ok, account}, else: :none

      _ ->
        :none
    end
  end

  # Search each value as a shipperReference in the one account and collect every
  # matching waybill number (deduped), plus a tool_log entry per value.
  defp shipper_ref_numbers(values, account) do
    results =
      for value <- values do
        params = %{reference: value, account: account}
        {value, safe_fetch(fn -> Adapters.fetch(:waybill_search, params) end, :waybill_search)}
      end

    entries =
      for {v, r} <- results,
          do: fetch_entry("FreightWare", :waybill_search, %{reference: v, account: account}, r)

    numbers =
      for {_v, {:ok, %{"waybill_numbers" => ns}}} <- results, n <- ns, uniq: true, do: n

    {numbers, entries}
  end

  defp waybill_sub(number),
    do: %{
      intent: :load_status,
      entities: %{waybill: number},
      entity: :waybill,
      entity_key: number
    }

  defp process_surface(question, subreqs, context) do
    interpret_entry = multi_interpret_entry(question, subreqs)
    valid = Enum.filter(subreqs, &(Validator.validate(&1) == :ok))

    case valid do
      [] ->
        first = hd(subreqs)

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
            {results, phrase_entries} = harmonize_and_phrase(question, groups, context)

            create_surface(
              question,
              results,
              context,
              [interpret_entry | fetch_entries] ++ phrase_entries
            )
        end
    end
  end

  # Group the gathered slices by domain entity (first-seen order), harmonise each
  # group into one record (Harmonize.project — first-writer-wins by source
  # priority), and phrase one cohesive answer per entity.
  defp harmonize_and_phrase(question, groups, context) do
    on_chunk = context[:on_chunk]
    keys = groups |> Enum.map(&{&1.entity, &1.entity_key}) |> Enum.uniq()

    {results, entries} =
      Enum.map_reduce(keys, [], fn {entity, key}, acc ->
        slices = Enum.filter(groups, &(&1.entity == entity and &1.entity_key == key))
        merged = Harmonize.project(Enum.map(slices, &%{source: &1.source, data: &1.facts}))
        rep = hd(slices)
        # Phrase the harmonised record via the entity's canonical capability (so a
        # waybill reads as its status, not whichever slice returned first).
        intent = phrasing_intent(entity, slices)

        if is_function(on_chunk, 1),
          do: on_chunk.("\n\n#{entity_label(entity, key, intent)}\n")

        {:ok, answer} = CoreAI.phrase(intent, merged.fields, %{question: question}, on_chunk)

        entry =
          ai_entry(
            "CoreAI.phrase",
            %{
              "entity" => to_string(entity),
              "key" => to_string(key),
              "sources" => Enum.join(merged.sources, ", ")
            },
            %{"answer" => answer},
            true
          )

        result = %{
          entity: entity,
          entity_key: key,
          intent: rep.intent,
          entities: rep.entities,
          sources: merged.sources,
          fields: merged.fields,
          answer: answer
        }

        {result, [entry | acc]}
      end)

    {results, Enum.reverse(entries)}
  end

  # One harmonised entity → a flat record (consumable like any single lookup).
  # Several → a `results` list (rendered grouped by the console).
  defp create_surface(question, results, context, tool_log) do
    draft =
      results |> Enum.map(fn r -> "#{result_label(r)}\n#{r.answer}" end) |> Enum.join("\n\n")

    {facts, source} =
      case results do
        [one] -> {one.fields, Enum.join(one.sources, ", ")}
        many -> {%{"results" => Enum.map(many, &surface_result_map/1)}, surface_sources(many)}
      end

    create(
      %{
        question: question,
        intent: results |> Enum.map(&to_string(&1.intent)) |> Enum.uniq() |> Enum.join(", "),
        entities: results |> Enum.flat_map(&Map.to_list(&1.entities)) |> Map.new() |> stringify(),
        facts: facts,
        source: source,
        tool_log: tool_log,
        draft_answer: draft,
        status: :drafted,
        agent: context[:agent]
      },
      context
    )
  end

  defp surface_sources(results),
    do:
      results
      |> Enum.flat_map(& &1.sources)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(", ")

  defp surface_result_map(r) do
    %{
      "intent" => to_string(r.intent),
      "source" => Enum.join(r.sources, ", "),
      "sources" => r.sources,
      "entities" => stringify(r.entities),
      "facts" => r.fields,
      "answer" => r.answer
    }
  end

  defp entity_label(nil, key, intent), do: "#{intent} (#{key})"
  defp entity_label(entity, key, _intent), do: "#{entity} #{key}"

  defp result_label(r), do: entity_label(r.entity, r.entity_key, r.intent)

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
        %{
          intent: r.intent,
          source: src,
          entities: r.entities,
          entity: Map.get(r, :entity),
          entity_key: Map.get(r, :entity_key),
          facts: facts
        }
      end

    {groups, fetch_entries}
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

  # Fetch the live fact via the source adapters. A misconfigured/unreachable
  # source (e.g. missing Dovetail credentials) raises or exits deep in an
  # adapter/GenServer; catch it here so a single source being down degrades to a
  # graceful "not connected" reply instead of crashing the turn.
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

  # The PII-bearing fields fetched/produced for a turn — never persisted; carried
  # only in the in-memory record the engine returns for this turn.
  @transient_keys [:facts, :tool_log, :draft_answer, :final_answer]

  # Persist only the slim dashboard-stats metadata (stamping the ticket for
  # grouping and the loop latency), then return an in-memory record that also
  # carries the transient fields for this turn's rendering / ticket draft.
  defp create(attrs, context) do
    attrs =
      attrs
      |> Map.put(:ticket_id, context[:ticket_id])
      |> Map.put(:duration_ms, elapsed_ms(context))

    {transient, slim} = Map.split(attrs, @transient_keys)

    case Assist.create_interaction(slim) do
      {:ok, rec} ->
        # Push the live monitor; harmless when there are no subscribers.
        TragarAi.Dashboard.broadcast()
        {:ok, live_record(rec, transient)}

      err ->
        err
    end
  end

  # The persisted slim row + the turn's transient (PII) fields, as a plain map so
  # `record.facts` / `record.draft_answer` etc. keep working downstream.
  defp live_record(rec, transient) do
    %{
      id: rec.id,
      question: rec.question,
      intent: rec.intent,
      entities: rec.entities,
      source: rec.source,
      status: rec.status,
      error: rec.error,
      agent: rec.agent,
      ticket_id: rec.ticket_id,
      duration_ms: rec.duration_ms,
      inserted_at: rec.inserted_at,
      facts: %{},
      tool_log: [],
      draft_answer: nil,
      final_answer: nil
    }
    |> Map.merge(transient)
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

  # This turn's freshly-extracted entities win; carried conversation/agent entities
  # only FILL what this turn didn't mention. So a follow-up that names a new
  # waybill switches to it, while a bare "and its ETA?" keeps the prior one. (The
  # earlier precedence let a carried reference override the new one → every
  # follow-up re-answered the first waybill.) Account SCOPE is enforced separately
  # via `context.accounts`, so this never widens what a request may read.
  defp merge_entities(model_entities, context) do
    Map.merge(Map.get(context, :entities, %{}), model_entities || %{})
  end

  # In a conversation, a turn that only supplies an entity keeps the prior intent.
  defp effective_intent(:unknown, context), do: Map.get(context, :intent) || :unknown
  defp effective_intent(intent, _context), do: intent

  defp stringify(entities) when is_map(entities) do
    Map.new(entities, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify(_), do: %{}
end
