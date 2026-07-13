defmodule TragarAi.CoreAI.ModelSetting do
  @moduledoc """
  Runtime selection of the active local chat model, plus a reasoning (thinking)
  toggle for models that support it.

  Mirrors `TragarAi.Assist.SearchStrategy`: backed by application env so it can be
  flipped live from the settings page without a restart, falling back to the
  configured `CORE_AI_MODEL` (then the first listed model) on boot.

  Selecting a model asks Ollama to unload the others (`keep_alive: 0`) and warm the
  chosen one (`keep_alive: -1`), so only one ~14B model is resident at a time — this
  box has 32 GB and shares it with the live app, so two 14B models will not co-exist.
  The swap runs in the background; the setting itself applies immediately.
  """

  # Atom app-env keys (Elixir 1.19 deprecates non-atom keys).
  @model_key :core_ai_active_model
  @reasoning_key :core_ai_reasoning_enabled

  # Selectable chat models, in display order (first = default). `reasoning: true`
  # marks models that support Ollama's `think` field (Qwen3). Add the 30B here if
  # you ever want it selectable again.
  @models [
    %{
      tag: "qwen2.5:14b-instruct",
      label: "Qwen2.5 14B",
      reasoning: false,
      describe: "Fast, instruction-tuned generalist. No reasoning mode. The original default."
    },
    %{
      tag: "qwen3:14b",
      label: "Qwen3 14B",
      reasoning: true,
      describe:
        "Newer generation, same family as the 30B. Supports a reasoning (thinking) " <>
          "mode you can toggle below."
    }
  ]

  @doc "Every selectable model (full metadata maps, display order)."
  def all, do: @models

  @doc "Just the model tags."
  def tags, do: Enum.map(@models, & &1.tag)

  @doc """
  The boot default: the configured `CORE_AI_MODEL` when set (so existing prod
  behaviour is preserved), otherwise the first listed model.
  """
  def default do
    case Application.get_env(:tragar_ai, TragarAi.CoreAI, [])[:model] do
      tag when is_binary(tag) and tag != "" -> tag
      _ -> hd(@models).tag
    end
  end

  @doc "The active model tag."
  def get, do: Application.get_env(:tragar_ai, @model_key, default())

  @doc """
  Set the active model at runtime. Returns `{:ok, tag}` for a known model, or
  `{:error, :unknown_model}` otherwise. Triggers a background load-one/unload-others
  swap in Ollama so only the chosen model stays resident.
  """
  def set(tag) when is_binary(tag) do
    if tag in tags() do
      Application.put_env(:tragar_ai, @model_key, tag)
      swap_resident(tag)
      {:ok, tag}
    else
      {:error, :unknown_model}
    end
  end

  def set(_), do: {:error, :unknown_model}

  @doc "Human-readable label for a model tag."
  def label(tag), do: field(tag, :label, tag)

  @doc "One-line description of a model tag."
  def describe(tag), do: field(tag, :describe, "")

  @doc "Whether a model supports the reasoning (thinking) mode."
  def reasoning_capable?(tag), do: field(tag, :reasoning, false) == true

  @doc "The metadata map for a tag, or nil if unknown."
  def meta(tag), do: Enum.find(@models, &(&1.tag == tag))

  @doc "Whether the reasoning toggle is on (independent of the active model)."
  def reasoning_enabled?, do: Application.get_env(:tragar_ai, @reasoning_key, false)

  @doc "Turn the reasoning toggle on/off. Returns `{:ok, on}`."
  def set_reasoning_enabled(on) when is_boolean(on) do
    Application.put_env(:tragar_ai, @reasoning_key, on)
    {:ok, on}
  end

  @doc """
  Clear both runtime overrides, reverting to the configured defaults (the
  `CORE_AI_MODEL` model and reasoning off). Mainly for test isolation.
  """
  def reset do
    Application.delete_env(:tragar_ai, @model_key)
    Application.delete_env(:tragar_ai, @reasoning_key)
    :ok
  end

  @doc """
  Whether generations should actually run with thinking on right now: the toggle
  is on AND the active model supports reasoning. `model_thinks?/1` answers the same
  for an explicitly named model (used when a call targets a model directly).
  """
  def thinking_active?, do: model_thinks?(get())

  def model_thinks?(tag), do: reasoning_enabled?() and reasoning_capable?(tag)

  defp field(tag, key, fallback) do
    case meta(tag) do
      %{^key => value} -> value
      _ -> fallback
    end
  end

  # Unload every other selectable model, then warm the chosen one, in the
  # background so the settings click returns immediately. Best-effort; the
  # unload/preload calls no-op unless CoreAI is in :ollama mode.
  defp swap_resident(tag) do
    Task.start(fn ->
      for other <- tags(), other != tag, do: TragarAi.CoreAI.unload(other)
      TragarAi.CoreAI.preload(tag)
    end)

    :ok
  end
end
