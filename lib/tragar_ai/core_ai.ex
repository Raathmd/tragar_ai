defmodule TragarAi.CoreAI do
  @moduledoc """
  The local model — the "Core AI". It has exactly two jobs and is never the
  authority on a fact:

    * `interpret/2` — turn a free-form question into a **structured request**
      `%{intent: atom, entities: map, raw: question}`.
    * `phrase/3`   — turn fetched facts into a clear, customer-ready **draft
      answer** (which an agent then reviews).

  The model interprets and phrases; Elixir validates and fetches. The model
  never touches the source systems and never speaks to the customer directly.

  Modes (config `:mode`):

    * `:ollama` — the real deployment. Talks **directly to Ollama** (qwen3:30b)
      over `{base_url}/api/chat`: a structured-JSON `interpret` constrained to the
      allowed intent set, and a grounded `phrase`. If Ollama/qwen is not running
      (or errors), it **falls back to the deterministic stub** so the loop never
      breaks — qwen is primary, the stub is the safety net.
    * `:http` — POST to a separate model sidecar `{base_url}/interpret` and
      `/phrase` (the optional `coreai/` service). Not used for qwen.
    * `:stub` — a deterministic, in-process rule/template interpreter+phraser, so
      the whole loop runs end-to-end without any model.

  The contract is identical regardless of which provider answers, so nothing
  downstream changes.
  """

  require Logger

  alias TragarAi.CoreAI.Redact

  @type request :: %{intent: atom(), entities: map(), raw: String.t()}

  @doc "Interpret a free-form question into a structured request."
  @spec interpret(String.t(), map()) :: {:ok, request()} | {:error, term()}
  def interpret(question, context \\ %{}) when is_binary(question) do
    case mode() do
      :ollama ->
        with_fallbacks(
          order(
            [fn -> ollama_interpret(question, context) end],
            cloud_interpret_attempts(question, context)
          ),
          fn -> {:ok, ensure_intents(__MODULE__.Stub.interpret(question, context))} end,
          "interpret"
        )

      :http ->
        http_interpret(question, context)

      _ ->
        {:ok, ensure_intents(__MODULE__.Stub.interpret(question, context))}
    end
  end

  # The interpret backends produce one structured request per distinct lookup.
  # `finalize/2` returns the canonical shape: a list under `:intents`, with the
  # FIRST request's intent/entities mirrored at the top level for backward
  # compatibility (single-intent callers and tests read `:intent`/`:entities`).
  defp finalize(triples, question) do
    model_requests =
      Enum.map(triples, fn {name, args, scope} ->
        %{intent: constrain_intent(name), entities: atomize_entities(args), scope: scope}
      end)

    requests = Enum.uniq(model_requests ++ candidate_requests(question, model_requests))

    requests =
      if requests == [], do: [%{intent: :unknown, entities: %{}, scope: "one"}], else: requests

    first = hd(requests)

    %{
      intent: first.intent,
      entities: first.entities,
      scope: first.scope,
      intents: requests,
      raw: question
    }
  end

  # Interpret's job is to surface EVERY alphanumeric reference candidate in the text,
  # not just the model's single pick (qwen can latch onto a phone-number fragment and
  # miss the real waybill). Deterministically scan the question — which already includes
  # CSV/PDF attachment text via `Assist.Extract` — and add each candidate as a waybill
  # probe. NO cap: a ticket may attach a long list of waybills and every one must be
  # probed (the fan-out gathers facts for each and drops the ones that resolve to
  # nothing; its concurrency is bounded, not the candidate count). Gated to
  # shipment/unknown turns so a stray number in a quote/account turn can't hijack routing.
  @reference_re ~r/\b([A-Z]{2,4}-?\d{4,}[A-Z0-9-]*|\d{4,}[A-Z]{0,4})\b/i
  @candidate_intents [:load_status, :eta, :pod, :track, :route, :waybill_lookup, :unknown]

  defp candidate_requests(question, model_requests) when is_binary(question) do
    if candidate_turn?(model_requests) do
      already =
        model_requests
        |> Enum.flat_map(fn r -> [r.entities[:waybill], r.entities[:quote]] end)
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.upcase/1)
        |> MapSet.new()

      @reference_re
      |> Regex.scan(question, capture: :all_but_first)
      |> Enum.map(fn [m] -> String.upcase(m) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(already, &1))
      |> Enum.map(&%{intent: :load_status, entities: %{waybill: &1}, scope: "one"})
    else
      []
    end
  end

  defp candidate_requests(_question, _model_requests), do: []

  # Only add deterministic waybill candidates when the turn is about a shipment (or the
  # model couldn't classify it) — never on a quote/account/service/vehicle turn.
  defp candidate_turn?([%{intent: intent} | _]), do: intent in @candidate_intents
  defp candidate_turn?(_), do: true

  # Lift a single-request map (the stub) into the `:intents` list shape.
  defp ensure_intents(%{intent: intent, entities: entities} = req) do
    req
    |> Map.put_new(:scope, "one")
    |> Map.put_new(:intents, [%{intent: intent, entities: entities, scope: "one"}])
  end

  @doc """
  Phrase fetched facts into a clear draft answer. Pass `on_chunk` (a 1-arity fun)
  to stream the answer token-by-token (Ollama only); without it, returns the full
  answer. Non-Ollama providers emit the whole text as a single chunk.
  """
  @spec phrase(atom(), map(), map(), (String.t() -> any) | nil) ::
          {:ok, String.t()} | {:error, term()}
  def phrase(intent, facts, context \\ %{}, on_chunk \\ nil) do
    case mode() do
      :ollama ->
        with_fallbacks(
          order(
            [fn -> ollama_phrase(intent, facts, context, on_chunk) end],
            cloud_phrase_attempts(intent, facts, context, on_chunk)
          ),
          fn -> single_chunk(__MODULE__.Stub.phrase(intent, facts, context), on_chunk) end,
          "phrase"
        )

      :http ->
        case http_phrase(intent, facts, context) do
          {:ok, text} -> single_chunk(text, on_chunk)
          err -> err
        end

      _ ->
        single_chunk(__MODULE__.Stub.phrase(intent, facts, context), on_chunk)
    end
  end

  @doc """
  Generate a clarifying prompt-back when the request can't be matched to a Tragar
  intent/entity — the AI asks the user for what it needs instead of erroring.
  """
  @spec clarify(term()) :: {:ok, String.t()}
  def clarify(reason) do
    case mode() do
      :ollama ->
        facts = clarify_facts(reason)

        with_fallbacks(
          order(
            [fn -> ollama_phrase(:clarify, facts, %{}, nil) end],
            cloud_phrase_attempts(:clarify, facts, %{}, nil)
          ),
          fn -> {:ok, __MODULE__.Stub.clarify(reason)} end,
          "clarify"
        )

      :http ->
        http_clarify(reason)

      _ ->
        {:ok, __MODULE__.Stub.clarify(reason)}
    end
  end

  @doc """
  Extract the quick-quote slots a customer has stated across a (possibly
  multi-message) freight-quote conversation. Returns `{:ok, slots}` where `slots`
  is a string-keyed map holding ONLY the slots the model could read — any of
  `"service"`, `"collection"`, `"delivery"`, `"goods"`. The model only proposes;
  the caller validates completeness and calls FreightWare (`quick_quote` /
  `create_quote`). Falls back to the deterministic stub when qwen is down.
  """
  @spec quote_extract(String.t()) :: {:ok, map()}
  def quote_extract(transcript) when is_binary(transcript) do
    case mode() do
      :ollama ->
        with_fallbacks(
          order(
            [fn -> ollama_quote_extract(transcript) end],
            cloud_quote_extract_attempts(transcript)
          ),
          fn -> {:ok, __MODULE__.Stub.quote_extract(transcript)} end,
          "quote_extract"
        )

      _ ->
        {:ok, __MODULE__.Stub.quote_extract(transcript)}
    end
  end

  @doc """
  Free-form reasoning over a question, *without* a grounded fact lookup — used by
  the "reason freely" mode when validation or a lookup returns nothing. The answer
  is explicitly ungrounded (the model is told not to fabricate Tragar specifics).
  Falls back to the deterministic stub when qwen is down.
  """
  @spec reason(String.t(), map(), (String.t() -> any) | nil) ::
          {:ok, String.t()} | {:error, term()}
  def reason(question, context \\ %{}, on_chunk \\ nil) when is_binary(question) do
    case mode() do
      :ollama ->
        with_fallbacks(
          reason_attempts(question, context, on_chunk),
          fn -> single_chunk(__MODULE__.Stub.reason(question), on_chunk) end,
          "reason"
        )

      _ ->
        single_chunk(__MODULE__.Stub.reason(question), on_chunk)
    end
  end

  # Reason fallback chain: the deep reason model first (thinking on), then the
  # fast local model, before ever using the stub — so a flaky/unavailable 30B
  # degrades to the 14B's answer, not a canned rule-based reply. (Cloud models,
  # when configured, slot in here ahead of the stub.)
  defp reason_attempts(question, context, on_chunk) do
    models = Enum.uniq([active_reason_model(), ollama_model()])
    local = for m <- models, do: fn -> ollama_reason(question, context, on_chunk, m) end
    order(local, cloud_reason_attempts(question, context, on_chunk))
  end

  # ── Cloud tier (Claude, redacted) ────────────────────────────────────────────
  # Claude can serve either as the PRIMARY engine (when the active model's provider
  # is :cloud — the "Claude" setting) or as a FALLBACK behind the local model
  # (when a Qwen model is active). `order/2` decides which by putting the cloud
  # attempts first or last. Either way the cloud attempts are only present when the
  # tier is enabled. Sensitive values are redacted to [[N]] tokens before the
  # request and rehydrated before the answer is returned — Anthropic sees only
  # tokens.

  # Cloud-first when the operator selected Claude and the tier is usable; otherwise
  # local-first with cloud as a trailing fallback.
  defp order(local, cloud) do
    if use_cloud?(), do: cloud ++ local, else: local ++ cloud
  end

  defp use_cloud?,
    do: TragarAi.CoreAI.ModelSetting.cloud?() and __MODULE__.Cloud.enabled?()

  defp cloud_interpret_attempts(question, context) do
    if __MODULE__.Cloud.enabled?(),
      do: [fn -> cloud_interpret(question, context) end],
      else: []
  end

  defp cloud_phrase_attempts(intent, facts, context, on_chunk) do
    if __MODULE__.Cloud.enabled?(),
      do: [fn -> cloud_phrase(intent, facts, context, on_chunk) end],
      else: []
  end

  defp cloud_reason_attempts(question, context, on_chunk) do
    if __MODULE__.Cloud.enabled?(),
      do: [fn -> cloud_reason(question, context, on_chunk) end],
      else: []
  end

  defp cloud_quote_extract_attempts(transcript) do
    if __MODULE__.Cloud.enabled?(),
      do: [fn -> cloud_quote_extract(transcript) end],
      else: []
  end

  defp cloud_interpret(question, context) do
    map = redact_map(question, %{}, Map.get(context, :entities, %{}))

    with {:ok, content} <-
           cloud_chat_redacted(
             interpret_system_prompt(),
             interpret_user_prompt(question, context),
             map
           ),
         {:ok, body} <- Jason.decode(content) do
      requests =
        parse_interpret(body)
        |> Enum.map(fn {name, args} -> {name, restore_args(args, map)} end)

      {:ok, finalize(requests, question)}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:bad_json, e}}
      {:error, _} = err -> err
    end
  end

  defp cloud_phrase(intent, facts, context, on_chunk) do
    map = redact_map(Map.get(context, :question, ""), facts, Map.get(context, :entities, %{}))

    case cloud_chat_redacted(
           phrase_system_prompt(),
           phrase_user_prompt(intent, facts, context),
           map
         ) do
      {:ok, text} -> single_chunk(Redact.restore(clean(text), map), on_chunk)
      {:error, _} = err -> err
    end
  end

  defp cloud_reason(question, context, on_chunk) do
    map = redact_map(question, %{}, Map.get(context, :entities, %{}))

    case cloud_chat_redacted(
           reason_system_prompt(),
           interpret_user_prompt(question, context),
           map
         ) do
      {:ok, text} -> single_chunk(Redact.restore(clean(text), map), on_chunk)
      {:error, _} = err -> err
    end
  end

  defp cloud_quote_extract(transcript) do
    map = redact_map(transcript, %{}, %{})

    with {:ok, content} <- cloud_chat_redacted(quote_extract_prompt(), transcript, map),
         {:ok, body} <- Jason.decode(strip_think(content)) do
      slots =
        body
        |> take_quote_slots()
        |> Map.new(fn {k, v} -> {k, Redact.restore(v, map)} end)

      {:ok, slots}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:bad_json, e}}
      {:error, _} = err -> err
    end
  end

  # Build the user prompt with REAL values, then redact the whole thing — so any
  # secret that landed in either the question or the encoded context/facts is
  # tokenised before it leaves the network.
  defp cloud_chat_redacted(system, user, map) do
    [
      %{role: "system", content: strip_qwen_control(system) <> cloud_redaction_note()},
      %{role: "user", content: Redact.apply(user, map)}
    ]
    |> __MODULE__.Cloud.chat()
  end

  # `/no_think` and `/think` are Qwen-specific control tokens. Claude is no-think by
  # default (we never request extended thinking), so drop them from Claude-bound
  # prompts rather than shipping meaningless directives.
  defp strip_qwen_control(text) do
    text
    |> String.replace(~r{/no_think|/think}, "")
    |> String.trim_trailing()
  end

  defp redact_map(question, facts, entities) do
    (Redact.secrets(question, facts, entities) ++ Redact.identifiers(question))
    |> Redact.build()
  end

  defp restore_args(args, map) when is_map(args),
    do: Map.new(args, fn {k, v} -> {k, if(is_binary(v), do: Redact.restore(v, map), else: v)} end)

  defp restore_args(args, _map), do: args

  defp clean(text), do: text |> strip_think() |> String.trim()

  defp cloud_redaction_note do
    "\n\nNote: values shown as [[N]] (e.g. [[1]]) are redacted placeholders for " <>
      "private data. Preserve every [[N]] token exactly as-is in your output — do " <>
      "not alter, translate, drop, or invent placeholders."
  end

  @doc "Whether the real local model is reachable (always true in stub mode)."
  @spec available?() :: boolean()
  def available? do
    case mode() do
      :ollama ->
        match?(
          {:ok, %Req.Response{status: s}} when s in 200..499,
          Req.get(req(), url: "/api/tags")
        )

      :http ->
        match?({:ok, %Req.Response{status: s}} when s in 200..499, Req.get(req(), url: "/"))

      _ ->
        true
    end
  end

  def mode, do: Keyword.get(config(), :mode, :stub)
  defp config, do: Application.get_env(:tragar_ai, __MODULE__, [])

  @doc """
  Describe the model currently doing interpret/phrase, for display:
  `%{mode, label, model, provider, base_url}`.
  """
  @spec info() :: map()
  def info do
    cfg = config()
    mode = mode()
    base = Keyword.get(cfg, :base_url)

    # For real providers, reflect the *active* runtime model (settings-switchable),
    # not just the configured default. Stub mode has no model.
    {provider, label, model} =
      cond do
        mode == :ollama and use_cloud?() ->
          m = Keyword.get(cfg, :cloud_model) || "claude-haiku-4-5"
          {"Anthropic", "#{m} · Claude (cloud, redacted → local/stub fallback)", m}

        mode == :ollama ->
          m = ollama_model()
          {"Ollama", "#{m} · Ollama (→ stub fallback)", m}

        mode == :http ->
          m = ollama_model()
          prov = if base && String.contains?(base, "11434"), do: "Ollama", else: "sidecar"
          {prov, "#{m} · #{prov}", m}

        true ->
          m = Keyword.get(cfg, :model)
          {"in-process", m || "Core AI stub (rule-based)", m}
      end

    %{mode: mode, label: label, model: model, provider: provider, base_url: base}
  end

  # ── Ollama (qwen3:30b, direct) ──────────────────────────────────────────────

  # Try each attempt in order; first success wins. Only if every attempt fails do
  # we run `final` (the deterministic stub). This gives a model→model→stub chain
  # rather than a single primary→stub jump.
  defp with_fallbacks(attempts, final, what) do
    result =
      Enum.reduce_while(attempts, {:error, :no_attempts}, fn attempt, _acc ->
        case safe(attempt) do
          {:ok, _} = ok ->
            {:halt, ok}

          {:error, reason} ->
            Logger.warning("CoreAI #{what}: attempt failed (#{inspect(reason)}); trying next")
            {:cont, {:error, reason}}
        end
      end)

    case result do
      {:ok, _} = ok -> ok
      _ -> final.()
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp ollama_interpret(question, context) do
    messages = [
      %{role: "system", content: interpret_system_prompt()},
      %{role: "user", content: interpret_user_prompt(question, context)}
    ]

    # `format: "json"` constrains the decode grammar — the content is valid JSON,
    # so there is no thinking-tag preamble to strip.
    with {:ok, content} <- ollama_chat(messages, format: "json"),
         {:ok, body} <- Jason.decode(content) do
      {:ok, finalize(parse_interpret(body), question)}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:bad_json, e}}
      {:error, _} = err -> err
    end
  end

  defp ollama_quote_extract(transcript) do
    messages = [
      %{role: "system", content: quote_extract_prompt()},
      %{role: "user", content: transcript}
    ]

    with {:ok, content} <- ollama_chat(messages, format: "json"),
         {:ok, body} <- Jason.decode(content) do
      {:ok, take_quote_slots(body)}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:bad_json, e}}
      {:error, _} = err -> err
    end
  end

  # Keep only the known slot keys with non-blank string values.
  defp take_quote_slots(body) when is_map(body) do
    for key <- ~w(service collection delivery goods),
        value = body[key],
        is_binary(value),
        String.trim(value) != "",
        into: %{},
        do: {key, String.trim(value)}
  end

  defp take_quote_slots(_), do: %{}

  defp quote_extract_prompt do
    """
    You extract shipment details from a customer's freight-quote conversation for
    Tragar (a South African courier). Read EVERYTHING the customer has said so far
    and return ONLY a JSON object — no prose, no markdown, no code fences — with
    any of these keys you can determine. OMIT a key entirely if it isn't stated;
    never guess.

      - "service": one of Economy, Road Express, Overnight, Same-day, Abnormal
      - "collection": where it is collected FROM (the site/place, as stated)
      - "delivery": where it is delivered TO (the site/place, as stated)
      - "goods": what is shipped — contents, number of items, total mass, and the
        per-item dimensions, as stated

    Example: {"delivery":"Rendo's Audio, Moffett On Main","goods":"one 85\\" TV, 53.4 kg, 209x21x128 cm"}
    """
  end

  defp ollama_phrase(intent, facts, context, on_chunk) do
    [
      %{role: "system", content: phrase_system_prompt()},
      %{role: "user", content: phrase_user_prompt(intent, facts, context)}
    ]
    |> ollama_generate(on_chunk, ollama_model())
  end

  # "Reason freely" uses the active reasoning model (dashboard-switchable) — slower
  # and deeper, only invoked when the agent toggled it on. This is the only path
  # that runs with thinking ON (`think: true`); the model's reasoning streams in a
  # separate field we ignore, so the visible answer stays clean.
  defp ollama_reason(question, context, on_chunk, model) do
    [
      %{role: "system", content: reason_system_prompt()},
      %{role: "user", content: interpret_user_prompt(question, context)}
    ]
    |> ollama_generate(on_chunk, model, think: true)
  end

  # Stream when an on_chunk sink is given; otherwise one-shot. If streaming
  # errors mid-flight, fall back to a normal (non-stream) call so the caller
  # still gets a real model answer rather than the stub.
  defp ollama_generate(messages, on_chunk, model, opts \\ []) do
    # Thinking is OFF by default, so the fast structured steps (interpret, phrase)
    # never run in reasoning mode — grounded rendering doesn't benefit from it and
    # it costs ~10x latency. Only the explicit "reason freely" path opts in with
    # `think: true`.
    think = Keyword.get(opts, :think, false)

    result =
      if is_function(on_chunk, 1) do
        case ollama_chat_stream(messages, on_chunk, model, think) do
          {:ok, _} = ok -> ok
          {:error, _} -> ollama_chat(messages, model: model, think: think)
        end
      else
        ollama_chat(messages, model: model, think: think)
      end

    case result do
      {:ok, content} -> {:ok, content |> strip_think() |> String.trim()}
      {:error, _} = err -> err
    end
  end

  # Emit a one-shot value as a single chunk (non-Ollama providers / fallbacks),
  # so the UI still renders it even though it isn't token-streamed.
  defp single_chunk(text, on_chunk) when is_binary(text) do
    if is_function(on_chunk, 1), do: on_chunk.(text)
    {:ok, text}
  end

  defp ollama_chat(messages, opts) do
    model = Keyword.get(opts, :model) || ollama_model()

    body =
      %{
        model: model,
        messages: messages,
        stream: false,
        options: %{temperature: 0}
      }
      |> maybe_put(:format, Keyword.get(opts, :format))
      |> put_think(model, Keyword.get(opts, :think, false))

    case Req.post(req(), url: "/api/chat", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"message" => %{"content" => content}}}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, %Req.Response{status: status, body: rbody}} ->
        {:error, {:http_error, status, rbody}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Streaming chat: Ollama returns NDJSON (one JSON object per line, each with a
  # `message.content` token). We buffer across HTTP chunks, emit each token via
  # on_chunk, and return the full accumulated text. A thinking model streams its
  # reasoning in a separate `message.thinking` field (which we ignore) and keeps
  # `message.content` clean. The `into` fun runs in THIS process, so the
  # cross-chunk line buffer + accumulator live in the process dictionary.
  defp ollama_chat_stream(messages, on_chunk, model, think) do
    body =
      %{
        model: model,
        messages: messages,
        stream: true,
        options: %{temperature: 0}
      }
      |> put_think(model, think)

    Process.put({__MODULE__, :buf}, "")
    Process.put({__MODULE__, :acc}, "")

    result =
      Req.post(req(),
        url: "/api/chat",
        json: body,
        into: fn {:data, data}, {req, resp} ->
          consume_stream(data, on_chunk)
          {:cont, {req, resp}}
        end
      )

    acc = Process.get({__MODULE__, :acc}, "")
    Process.delete({__MODULE__, :buf})
    Process.delete({__MODULE__, :acc})

    case result do
      {:ok, %Req.Response{status: 200}} -> {:ok, acc}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_stream(data, on_chunk) do
    buf = Process.get({__MODULE__, :buf}, "") <> data
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    Process.put({__MODULE__, :buf}, rest)
    Enum.each(complete, &handle_stream_line(&1, on_chunk))
  end

  defp handle_stream_line("", _on_chunk), do: :ok

  defp handle_stream_line(line, on_chunk) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"content" => chunk}}} when is_binary(chunk) and chunk != "" ->
        Process.put({__MODULE__, :acc}, Process.get({__MODULE__, :acc}, "") <> chunk)
        on_chunk.(chunk)

      _ ->
        :ok
    end
  end

  # The tag used for the actual Ollama call — the local tier, and the fallback when
  # a cloud model (Claude) is active. When the active selection is itself a local
  # model, use it; when it's Claude, use the configured local model so the loop
  # degrades to a real local model, not straight to the stub.
  defp ollama_model do
    tag = TragarAi.CoreAI.ModelSetting.get()

    if TragarAi.CoreAI.ModelSetting.provider(tag) == :ollama,
      do: tag,
      else: TragarAi.CoreAI.ModelSetting.local_model()
  end

  @reason_key {__MODULE__, :active_reason_model}

  @doc """
  Reasoning-model control state for the dashboard:

    * `:active` — the model "reason freely" currently uses,
    * `:fast`   — the main model (default),
    * `:deep`   — the optional deeper model (`CORE_AI_REASON_MODEL`), or nil.
  """
  def reasoning do
    %{
      active: active_reason_model(),
      fast: ollama_model(),
      deep: Keyword.get(config(), :reason_model)
    }
  end

  @doc """
  Switch the active reasoning model at runtime (dashboard control). Must be one of
  the offered models (fast or deep). Node-global; resets to fast on restart.
  """
  @spec set_reasoning(String.t()) :: :ok | {:error, :unknown_model}
  def set_reasoning(model) when is_binary(model) and model != "" do
    %{fast: fast, deep: deep} = reasoning()

    if model in Enum.reject([fast, deep], &is_nil/1) do
      :persistent_term.put(@reason_key, model)
      # Free the deep model from memory immediately when it's no longer in use.
      if deep && deep != model && deep != fast, do: unload(deep)
      :ok
    else
      {:error, :unknown_model}
    end
  end

  @doc "Ask Ollama to unload a model from memory now (keep_alive: 0). Best-effort."
  @spec unload(String.t()) :: :ok
  def unload(model) when is_binary(model) do
    if mode() == :ollama do
      Req.post(req(),
        url: "/api/chat",
        json: %{model: model, messages: [], keep_alive: 0},
        receive_timeout: 10_000
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Warm a model into memory now and keep it resident (`keep_alive: -1`).
  Best-effort; no-ops unless we're talking to real Ollama.
  """
  @spec preload(String.t()) :: :ok
  def preload(model) when is_binary(model) do
    if mode() == :ollama do
      Req.post(req(),
        url: "/api/chat",
        json: %{model: model, messages: [], keep_alive: -1},
        receive_timeout: 60_000
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # The active "reason freely" model — runtime-switchable from the dashboard.
  # Defaults to the configured deep reason model (CORE_AI_REASON_MODEL) when set,
  # otherwise the fast main model.
  defp active_reason_model,
    do:
      :persistent_term.get(@reason_key, nil) || Keyword.get(config(), :reason_model) ||
        ollama_model()

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # Send the `think` flag only for models that support it (Qwen3), as an explicit
  # boolean. Qwen3 thinks BY DEFAULT, so to keep interpret/phrase fast we must send
  # `think: false` — omitting it isn't enough. Non-thinking models (e.g. qwen2.5)
  # get no `think` field at all, since some error when it's present.
  defp put_think(body, model, think) do
    if thinking_model?(model) do
      Map.put(body, :think, think == true)
    else
      body
    end
  end

  # The Qwen3 family supports Ollama's `think` flag (and thinks by default); other
  # models (qwen2.5, llama, …) don't, and can error if it's set.
  defp thinking_model?(model), do: is_binary(model) and String.starts_with?(model, "qwen3")

  # Some thinking models emit a <think>…</think> preamble in free-text replies.
  defp strip_think(text), do: Regex.replace(~r/<think>.*?<\/think>/s, text, "")

  # The model picks from the validator's allowed intents (the source of truth),
  # not an open-ended set. We list each intent and the entity it requires.
  defp interpret_system_prompt do
    # Group the capability catalogue by source so the model knows which source
    # serves what — and can route when a source is named (e.g. "call Vantage…").
    intents =
      TragarAi.Assist.Tools.catalog()
      |> Enum.group_by(&(&1.source || "Other"))
      |> Enum.sort_by(fn {source, _} -> source end)
      |> Enum.map_join("\n", fn {source, caps} ->
        lines =
          caps
          |> Enum.sort_by(& &1.intent)
          |> Enum.map_join("\n", fn c ->
            needs =
              if c.required == [],
                do: "",
                else: " — needs #{Enum.map_join(c.required, ", ", &to_string/1)}"

            desc = if c.description == "", do: "", else: " — #{c.description}"
            "    - #{c.intent}#{needs}#{desc}"
          end)

        "  #{source}:\n#{lines}"
      end)

    """
    You classify a customer's logistics question for Tragar (a South African
    courier). If the question is not in English, translate it first, then classify.

    Respond with ONLY a JSON object — no prose, no markdown, no code fences:
    {"intents": [{"intent": "<intent>", "entities": {"waybill": "...", "account": "...", "quote": "...", "ticket_id": "..."}, "scope": "all"}]}

    "scope" controls breadth for the entity:
    - "all" is the DEFAULT — surface EVERYTHING known about the entity across ALL
      sources (status, tracking, live location/route, etc.). Use "all" for any
      general question such as "where is X", "status of X", "track X", "delivery
      status of X", "what's happening with X", or "everything about X".
    - Use "one" ONLY when the customer explicitly limits the request to a single
      fact with a word like "just", "only", "nothing but", or "exactly" — e.g.
      "just the latest status", "only the ETA", "the POD only".
    If there is no such explicit limiter word, ALWAYS use "all".

    Return ONE entry in "intents" per distinct lookup the question needs:
    - If the customer asks several things about one reference (e.g. status AND ETA
      AND proof of delivery for a waybill), include one entry for each.
    - If the customer names several references (e.g. multiple waybills, or a
      waybill and an account), include one entry for each — you MAY repeat the
      same intent with different entities.
    - If it is a single request, return a one-element list.

    Include an entity key ONLY if you actually found its value in the question.

    Capabilities, grouped by the source system that serves them:
    #{intents}

    If the customer names a source system (e.g. "Vantage", "FreightWare",
    "Pastel"), choose a capability from THAT source. For example a route/tracking
    or vehicle question, or a request that names Vantage, should use Vantage's
    "route" / "vehicle_tracking" — not a FreightWare capability.

    If the question matches no intent, respond {"intents": [{"intent": "unknown", "entities": {}}]}.

    /no_think
    """
  end

  defp interpret_user_prompt(question, context) do
    history = history_text(context)

    ctx =
      case safe_context_json(context) do
        nil -> ""
        json -> "Context: #{json}\n"
      end

    "#{history}#{ctx}Question: #{question}"
  end

  # Prior turns of THIS console conversation as a compact transcript, so the model
  # can resolve follow-ups ("its ETA", "that one", "and the POD?") against what was
  # already asked and answered instead of the user having to repeat context.
  defp history_text(context) do
    case context[:history] do
      [_ | _] = turns ->
        lines =
          Enum.map_join(turns, "\n", fn %{role: role, text: text} -> "#{role}: #{text}" end)

        "Conversation so far:\n#{lines}\n\n"

      _ ->
        ""
    end
  end

  # The model only needs hint fields (entities, intent, ticket, accounts) — never
  # internal/runtime keys, and definitely not the `on_chunk` streaming function,
  # which isn't JSON-encodable and previously crashed interpret/reason into the
  # rule-based stub. Drop internal keys; if anything left is still non-encodable,
  # omit the context entirely rather than fail the model call.
  defp safe_context_json(context) do
    ctx =
      Map.drop(context, [
        :on_chunk,
        :on_event,
        :history,
        :started_at,
        :free_reasoning,
        :demo,
        :agent
      ])

    case map_size(ctx) do
      0 ->
        nil

      _ ->
        case Jason.encode(ctx) do
          {:ok, json} -> json
          {:error, _} -> nil
        end
    end
  end

  defp phrase_system_prompt do
    """
    You are a support assistant for Tragar, a South African logistics company.
    Turn the given facts into a clear, concise, friendly answer for the customer.

    Rules:
    - Use ONLY the facts provided. Never invent waybill numbers, dates, statuses,
      prices, or any detail that is not in the facts.
    - Keep it to a few sentences. No markdown headings, no preamble.
    - If the facts indicate missing information or a not-found result, say so
      plainly and ask for what you need.
    - Write the answer in English by default. If the customer's question is
      clearly in another language, add the SAME answer in that language on a new
      line below, prefixed with the language name (e.g. "Afrikaans: ..."), so the
      agent can pick which version to send. If the question is in English, give
      the English answer only.

    /no_think
    """
  end

  defp phrase_user_prompt(intent, facts, _context),
    do: "Intent: #{intent}\nFacts (JSON):\n#{Jason.encode!(facts)}"

  defp reason_system_prompt do
    """
    You are the Tragar support assistant. For THIS question there is no grounded
    system fact available — either it isn't a Tragar lookup, or the lookup returned
    nothing. Reason it through and give your most helpful answer anyway.

    Rules:
    - Do NOT fabricate waybill numbers, dates, statuses, prices, or account data.
      If a specific record is needed, say it must be confirmed in the system.
    - It is fine to explain, advise, translate, or reason generally.
    - Be concise. Answer in English by default; if the question is clearly in
      another language, add the same answer in that language on a new line below,
      prefixed with the language name, so the agent can choose which to send.

    /think
    """
  end

  # ── HTTP (real sidecar) ─────────────────────────────────────────────────────

  defp http_interpret(question, context) do
    # Hand the model the tool/function schema so it can only pick a valid call.
    payload = %{question: question, context: context, tools: TragarAi.Assist.Tools.schema()}

    case Req.post(req(), url: "/interpret", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, finalize(parse_interpret(body), question)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse the model's reply into a LIST of `{name, args}` — one per requested
  # lookup. Accepts a multi shape (`{"intents":[...]}` / `{"tool_calls":[...]}`)
  # or a single object (function-calling `tool_call`, or flat intent/entities),
  # which becomes a one-element list.
  defp parse_interpret(%{"intents" => list}) when is_list(list), do: Enum.map(list, &parse_one/1)

  defp parse_interpret(%{"tool_calls" => list}) when is_list(list),
    do: Enum.map(list, &parse_one/1)

  defp parse_interpret(other), do: [parse_one(other)]

  defp parse_one(%{"tool_call" => %{"name" => name} = call} = item),
    do: {name, call["arguments"] || call["entities"] || %{}, scope_of(item)}

  defp parse_one(%{"name" => name} = call),
    do: {name, call["arguments"] || call["entities"] || %{}, scope_of(call)}

  defp parse_one(item) when is_map(item),
    do: {item["intent"], item["entities"] || %{}, scope_of(item)}

  defp parse_one(_), do: {nil, %{}, "one"}

  # Breadth signal: "all" → surface every facet of the entity; "one" → just this
  # capability. Code default is "one" (safe); the system prompt tells the model to
  # default to "all" and only narrow for explicit single-fact asks.
  defp scope_of(%{"scope" => s}) when s in ["all", "one"], do: s
  defp scope_of(_), do: "one"

  # The model may only resolve to an allowed intent; anything else is :unknown.
  defp constrain_intent(name) do
    intent = to_atom(name)
    if intent in TragarAi.Assist.Validator.allowed_intents(), do: intent, else: :unknown
  end

  # Elixir decides the situation (grounded); the model phrases it. Falls back to
  # the deterministic template if the model is unreachable or errors.
  defp http_clarify(reason) do
    payload = %{intent: "clarify", facts: clarify_facts(reason), context: %{}}

    case Req.post(req(), url: "/phrase", json: payload) do
      {:ok, %Req.Response{status: 200, body: %{"answer" => answer}}} when is_binary(answer) ->
        {:ok, answer}

      _ ->
        {:ok, __MODULE__.Stub.clarify(reason)}
    end
  end

  defp clarify_facts({:missing_entities, missing}),
    do: %{"situation" => "missing_information", "needed" => Enum.map(missing, &to_string/1)}

  defp clarify_facts(:not_found),
    do: %{"situation" => "reference_not_found", "capabilities" => capability_names()}

  defp clarify_facts(other),
    do: %{"situation" => to_string(other), "capabilities" => capability_names()}

  defp capability_names, do: Enum.map(TragarAi.Assist.Tools.schema(), & &1["name"])

  defp http_phrase(intent, facts, context) do
    payload = %{intent: intent, facts: facts, context: context}

    case Req.post(req(), url: "/phrase", json: payload) do
      {:ok, %Req.Response{status: 200, body: %{"answer" => answer}}} -> {:ok, answer}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    [
      base_url: Keyword.fetch!(config(), :base_url),
      receive_timeout: Keyword.get(config(), :receive_timeout, 30_000)
    ]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new()
  end

  # Only the entity keys the validator/connectors understand are accepted; the
  # model's JSON gives string keys, which we map to the known atoms.
  @entity_keys %{
    "waybill" => :waybill,
    "ticket_id" => :ticket_id,
    "account" => :account,
    "quote" => :quote
  }

  defp atomize_entities(map) when is_map(map) do
    for {k, v} <- map,
        key = @entity_keys[to_string(k)],
        not is_nil(v) and v != "",
        into: %{},
        do: {key, v}
  end

  defp atomize_entities(_), do: %{}

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end

  defp to_atom(_), do: :unknown
end
