defmodule TragarAi.CoreAI.Redact do
  @moduledoc """
  Placeholder substitution for the cloud (Claude) fallback tier.

  The local Ollama models run on-prem, so the grounded loop sends real customer
  data to them freely. The cloud tier does not get that trust: before any text
  leaves the network we replace sensitive values (the request's entities plus
  PII-ish fact fields) with opaque `[[N]]` tokens, send only the tokenised text,
  and then **rehydrate** the real values back into the model's answer before it
  is shown. Anthropic only ever sees `[[1]]`, never the waybill or the name.

  Flow:

      map = build(secrets(question, facts, entities))
      redacted_prompt = apply(prompt, map)
      {:ok, answer} = Cloud.chat(... redacted_prompt ...)
      restore(answer, map)   # real values back in
  """

  # Fact keys whose values are treated as private. Key-driven (not value-driven)
  # so we never under-redact a known-PII field.
  @pii_key ~r/name|email|phone|mobile|street|address|suburb|city|postal|receiver|consignee|consignor|waybill|account|quote|invoice|reference|contact|pod/i

  @doc """
  Collect the sensitive string values to redact: every entity value, plus every
  scalar fact value whose key looks like PII. Deduped, blanks dropped.
  """
  @spec secrets(String.t(), map(), map()) :: [String.t()]
  def secrets(_question, facts, entities) do
    entity_values = for {_k, v} <- safe_map(entities), is_binary(v), do: v
    fact_values = collect_facts(facts)

    (entity_values ++ fact_values)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Free-text identifier patterns — for redacting a customer's typed question,
  # where the sensitive values (waybill, account, quote, ticket, email, phone)
  # aren't yet enumerated. Heuristic; pairs with the exact entity/fact redaction.
  @id_patterns [
    # email
    ~r/[\w.+-]+@[\w-]+\.[\w.-]+/,
    # phone (7+ digits, allowing spaces/()-/+)
    ~r/\+?\d[\d ()\-]{6,}\d/,
    # account/quote-ish codes: letters then digits (ACC1001, ITD02)
    ~r/\b[A-Za-z]{2,}\d{2,}[A-Za-z0-9]*\b/,
    # waybill-ish: alphanumeric run of 5+ containing a digit (0006794936FC)
    ~r/\b(?=[0-9A-Za-z]*\d)[0-9A-Za-z]{5,}\b/,
    # bare numbers of 3+ digits (quotes, ticket ids, short waybills)
    ~r/\b\d{3,}\b/
  ]

  @doc """
  Heuristically extract identifier-like substrings from free text (the question),
  so the cloud tier can redact them even before the model has parsed entities.
  """
  @spec identifiers(String.t()) :: [String.t()]
  def identifiers(text) when is_binary(text) do
    @id_patterns
    |> Enum.flat_map(fn re -> Regex.scan(re, text) |> Enum.map(&hd/1) end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def identifiers(_), do: []

  @doc "Build a `token => real` map, longest values first so tokens are stable."
  @spec build([String.t()]) :: %{optional(String.t()) => String.t()}
  def build(values) do
    values
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.with_index(1)
    |> Map.new(fn {value, i} -> {"[[#{i}]]", value} end)
  end

  @doc "Replace each real value with its token (longest real value first)."
  @spec apply(String.t(), map()) :: String.t()
  def apply(text, map) when is_binary(text) do
    map
    |> Enum.sort_by(fn {_tok, real} -> String.length(real) end, :desc)
    |> Enum.reduce(text, fn {token, real}, acc -> String.replace(acc, real, token) end)
  end

  @doc "Replace each token with its real value."
  @spec restore(String.t(), map()) :: String.t()
  def restore(text, map) when is_binary(text) do
    Enum.reduce(map, text, fn {token, real}, acc -> String.replace(acc, token, real) end)
  end

  # Walk a facts map (possibly nested via the multi-lookup "results" shape) and
  # collect scalar values under PII-ish keys.
  defp collect_facts(facts) when is_map(facts) do
    Enum.flat_map(safe_map(facts), fn
      {k, v} when is_binary(v) -> if pii?(k), do: [v], else: []
      {_k, v} when is_map(v) -> collect_facts(v)
      {_k, v} when is_list(v) -> Enum.flat_map(v, &collect_facts/1)
      _ -> []
    end)
  end

  defp collect_facts(_), do: []

  defp pii?(key), do: Regex.match?(@pii_key, to_string(key))

  defp safe_map(m) when is_map(m), do: m
  defp safe_map(_), do: %{}
end
