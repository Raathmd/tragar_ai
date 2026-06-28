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

  @type request :: %{intent: atom(), entities: map(), raw: String.t()}

  @doc "Interpret a free-form question into a structured request."
  @spec interpret(String.t(), map()) :: {:ok, request()} | {:error, term()}
  def interpret(question, context \\ %{}) when is_binary(question) do
    case mode() do
      :ollama ->
        with_fallback(
          fn -> ollama_interpret(question, context) end,
          fn -> {:ok, __MODULE__.Stub.interpret(question, context)} end,
          "interpret"
        )

      :http ->
        http_interpret(question, context)

      _ ->
        {:ok, __MODULE__.Stub.interpret(question, context)}
    end
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
        with_fallback(
          fn -> ollama_phrase(intent, facts, context, on_chunk) end,
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
        with_fallback(
          fn -> ollama_phrase(:clarify, clarify_facts(reason), %{}, nil) end,
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
        with_fallback(
          fn -> ollama_reason(question, context, on_chunk) end,
          fn -> single_chunk(__MODULE__.Stub.reason(question), on_chunk) end,
          "reason"
        )

      _ ->
        single_chunk(__MODULE__.Stub.reason(question), on_chunk)
    end
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
    model = Keyword.get(cfg, :model)

    reason_model = Keyword.get(cfg, :reason_model)

    {provider, label} =
      case mode do
        :ollama ->
          reason =
            if reason_model && reason_model != model, do: " · reason: #{reason_model}", else: ""

          {"Ollama", "#{model || "qwen3:30b"}#{reason} · Ollama (→ stub fallback)"}

        :http ->
          prov = if base && String.contains?(base, "11434"), do: "Ollama", else: "sidecar"
          {prov, "#{model || "local model"} · #{prov}"}

        _ ->
          {"in-process", model || "Core AI stub (rule-based)"}
      end

    %{mode: mode, label: label, model: model, provider: provider, base_url: base}
  end

  # ── Ollama (qwen3:30b, direct) ──────────────────────────────────────────────

  # Run the primary; on any error/exception, log and use the deterministic
  # fallback. This is what makes the stub the safety net when qwen is down.
  defp with_fallback(primary, fallback, what) do
    case safe(primary) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "CoreAI #{what}: qwen/Ollama unavailable (#{inspect(reason)}); using fallback"
        )

        fallback.()
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
      {name, args} = parse_interpret(body)

      {:ok, %{intent: constrain_intent(name), entities: atomize_entities(args), raw: question}}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:bad_json, e}}
      {:error, _} = err -> err
    end
  end

  defp ollama_phrase(intent, facts, context, on_chunk) do
    [
      %{role: "system", content: phrase_system_prompt()},
      %{role: "user", content: phrase_user_prompt(intent, facts, context)}
    ]
    |> ollama_generate(on_chunk, ollama_model())
  end

  # "Reason freely" uses the (optionally separate) reasoning model — slower and
  # deeper, only invoked when the agent toggled it on.
  defp ollama_reason(question, context, on_chunk) do
    [
      %{role: "system", content: reason_system_prompt()},
      %{role: "user", content: interpret_user_prompt(question, context)}
    ]
    |> ollama_generate(on_chunk, ollama_reason_model())
  end

  # Stream when an on_chunk sink is given; otherwise one-shot. If streaming
  # errors mid-flight, fall back to a normal (non-stream) call so the caller
  # still gets a real model answer rather than the stub.
  defp ollama_generate(messages, on_chunk, model) do
    result =
      if is_function(on_chunk, 1) do
        case ollama_chat_stream(messages, on_chunk, model) do
          {:ok, _} = ok -> ok
          {:error, _} -> ollama_chat(messages, model: model)
        end
      else
        ollama_chat(messages, model: model)
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
    body =
      %{
        model: Keyword.get(opts, :model) || ollama_model(),
        messages: messages,
        stream: false,
        options: %{temperature: 0}
      }
      |> maybe_put(:format, Keyword.get(opts, :format))

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
  defp ollama_chat_stream(messages, on_chunk, model) do
    body = %{
      model: model,
      messages: messages,
      stream: true,
      options: %{temperature: 0}
    }

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

  defp ollama_model, do: Keyword.get(config(), :model) || "qwen3:30b"

  # The reasoning model for "reason freely"; falls back to the main model.
  defp ollama_reason_model, do: Keyword.get(config(), :reason_model) || ollama_model()

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # Some thinking models emit a <think>…</think> preamble in free-text replies.
  defp strip_think(text), do: Regex.replace(~r/<think>.*?<\/think>/s, text, "")

  # The model picks from the validator's allowed intents (the source of truth),
  # not an open-ended set. We list each intent and the entity it requires.
  defp interpret_system_prompt do
    intents =
      TragarAi.Assist.Validator.required()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {intent, req} ->
        needs = if req == [], do: "", else: " — needs #{Enum.map_join(req, ", ", &to_string/1)}"
        "  - #{intent}#{needs}"
      end)

    """
    You classify a customer's logistics question for Tragar (a South African
    courier). If the question is not in English, translate it first, then classify.

    Respond with ONLY a JSON object — no prose, no markdown, no code fences:
    {"intent": "<one intent>", "entities": {"waybill": "...", "account": "...", "quote": "...", "ticket_id": "..."}}

    Include an entity key ONLY if you actually found its value in the question.
    Valid intents (pick exactly one):
    #{intents}

    If the question matches no intent, respond {"intent": "unknown", "entities": {}}.
    """
  end

  defp interpret_user_prompt(question, context) when context == %{},
    do: question

  defp interpret_user_prompt(question, context),
    do: "Context: #{Jason.encode!(context)}\nQuestion: #{question}"

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
    - Reply in the customer's language if it is evident from the question.
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
    - Be concise. Reply in the customer's language if it is evident.
    """
  end

  # ── HTTP (real sidecar) ─────────────────────────────────────────────────────

  defp http_interpret(question, context) do
    # Hand the model the tool/function schema so it can only pick a valid call.
    payload = %{question: question, context: context, tools: TragarAi.Assist.Tools.schema()}

    case Req.post(req(), url: "/interpret", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {name, args} = parse_interpret(body)

        {:ok,
         %{
           intent: constrain_intent(name),
           entities: atomize_entities(args),
           raw: question
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Accept either a function-calling shape (`tool_call`) or a flat intent/entities.
  defp parse_interpret(%{"tool_call" => %{"name" => name} = call}),
    do: {name, call["arguments"] || call["entities"] || %{}}

  defp parse_interpret(body), do: {body["intent"], body["entities"] || %{}}

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
