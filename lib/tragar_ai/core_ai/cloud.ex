defmodule TragarAi.CoreAI.Cloud do
  @moduledoc """
  Cloud fallback tier — Anthropic's Claude (`claude-haiku-4-5` by default), used
  ONLY when local Ollama is unavailable AND the operator has enabled it
  (`CORE_AI_CLOUD_ENABLED=true`). It sits ahead of the deterministic stub in the
  CoreAI fallback chain.

  Privacy: callers redact sensitive values to `[[N]]` tokens (see
  `TragarAi.CoreAI.Redact`) before calling `chat/2`, and rehydrate the real
  values into the answer afterwards — Anthropic only ever sees tokens.

  Non-streaming by design: the full answer is fetched, then rehydrated, then
  emitted, so no partial token can leak an un-rehydrated placeholder.
  """

  require Logger

  @anthropic_version "2023-06-01"

  defp config, do: Application.get_env(:tragar_ai, TragarAi.CoreAI, [])

  @doc "True when the cloud tier is switched on and an API key is configured."
  @spec enabled?() :: boolean()
  def enabled? do
    cfg = config()
    Keyword.get(cfg, :cloud_enabled, false) and is_binary(Keyword.get(cfg, :cloud_api_key))
  end

  @doc """
  Send our internal message list to the Anthropic Messages API and return the
  assistant's text. The `system`-role entries become the API's top-level
  `system` string; the rest become `messages` (user/assistant only).
  """
  @spec chat([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) do
    cfg = config()
    api_key = Keyword.get(cfg, :cloud_api_key)

    if is_binary(api_key) do
      {system, turns} = split_system(messages)

      body = %{
        model: Keyword.get(opts, :model) || Keyword.get(cfg, :cloud_model) || "claude-haiku-4-5",
        max_tokens: Keyword.get(opts, :max_tokens, 1024),
        system: system,
        messages: turns
      }

      req =
        Req.new(
          url: Keyword.get(cfg, :cloud_url) || "https://api.anthropic.com/v1/messages",
          receive_timeout: Keyword.get(cfg, :receive_timeout, 30_000),
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", @anthropic_version},
            {"content-type", "application/json"}
          ]
        )
        |> Req.merge(Keyword.get(cfg, :cloud_req_options, []))

      case Req.post(req, json: body) do
        {:ok, %Req.Response{status: 200, body: rbody}} ->
          extract_text(rbody)

        {:ok, %Req.Response{status: status, body: rbody}} ->
          {:error, {:http_error, status, rbody}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_api_key}
    end
  end

  # Anthropic wants `system` as a top-level string and `messages` as
  # user/assistant turns. We only ever build one system + one user message.
  defp split_system(messages) do
    {system_msgs, turns} =
      Enum.split_with(messages, &(&1[:role] == "system" or &1["role"] == "system"))

    system = system_msgs |> Enum.map_join("\n\n", &content(&1))
    turns = Enum.map(turns, fn m -> %{role: m[:role] || m["role"], content: content(m)} end)
    turns = if turns == [], do: [%{role: "user", content: ""}], else: turns
    {system, turns}
  end

  defp content(m), do: m[:content] || m["content"] || ""

  defp extract_text(%{"content" => blocks}) when is_list(blocks) do
    case Enum.find(blocks, &(&1["type"] == "text")) do
      %{"text" => t} when is_binary(t) -> {:ok, t}
      _ -> {:error, :no_text_block}
    end
  end

  defp extract_text(other), do: {:error, {:bad_body, other}}
end
