defmodule TragarAi.CoreAI do
  @moduledoc """
  The local model — the "Core AI", reached over local HTTP (the Swift sidecar on
  the Mac). It has exactly two jobs and is never the authority on a fact:

    * `interpret/2` — turn a free-form question into a **structured request**
      `%{intent: atom, entities: map, raw: question}`.
    * `phrase/3`   — turn fetched facts into a clear, customer-ready **draft
      answer** (which an agent then reviews).

  The model interprets and phrases; Elixir validates and fetches. The model
  never touches the source systems and never speaks to the customer directly.

  Two modes (config `:mode`):

    * `:stub` — a deterministic, in-process rule/template interpreter+phraser, so
      the whole loop runs end-to-end without a model. The contract is identical
      to the real sidecar, so nothing downstream changes when the model arrives.
    * `:http` — POST to the local sidecar `{base_url}/interpret` and `/phrase`.
  """

  require Logger

  @type request :: %{intent: atom(), entities: map(), raw: String.t()}

  @doc "Interpret a free-form question into a structured request."
  @spec interpret(String.t(), map()) :: {:ok, request()} | {:error, term()}
  def interpret(question, context \\ %{}) when is_binary(question) do
    case mode() do
      :http -> http_interpret(question, context)
      _ -> {:ok, __MODULE__.Stub.interpret(question, context)}
    end
  end

  @doc "Phrase fetched facts into a clear draft answer."
  @spec phrase(atom(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def phrase(intent, facts, context \\ %{}) do
    case mode() do
      :http -> http_phrase(intent, facts, context)
      _ -> {:ok, __MODULE__.Stub.phrase(intent, facts, context)}
    end
  end

  @doc "Whether the real local model is reachable (always true in stub mode)."
  @spec available?() :: boolean()
  def available? do
    case mode() do
      :http ->
        match?({:ok, %Req.Response{status: s}} when s in 200..499, Req.get(req(), url: "/"))

      _ ->
        true
    end
  end

  def mode, do: Keyword.get(config(), :mode, :stub)
  defp config, do: Application.get_env(:tragar_ai, __MODULE__, [])

  # ── HTTP (real sidecar) ─────────────────────────────────────────────────────

  defp http_interpret(question, context) do
    case Req.post(req(), url: "/interpret", json: %{question: question, context: context}) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{
           intent: to_atom(body["intent"]),
           entities: body["entities"] || %{},
           raw: question
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_phrase(intent, facts, context) do
    payload = %{intent: intent, facts: facts, context: context}

    case Req.post(req(), url: "/phrase", json: payload) do
      {:ok, %Req.Response{status: 200, body: %{"answer" => answer}}} -> {:ok, answer}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    Req.new(
      base_url: Keyword.fetch!(config(), :base_url),
      receive_timeout: Keyword.get(config(), :receive_timeout, 30_000)
    )
  end

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_existing_atom(value)
  defp to_atom(_), do: :unknown
end
