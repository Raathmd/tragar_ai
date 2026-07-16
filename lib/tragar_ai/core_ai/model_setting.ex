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

  # Atom app-env keys (Elixir 1.19 deprecates non-atom keys). Application env is the
  # fast in-memory cache; the same values are mirrored to the durable
  # `RuntimeSettings` store under the string keys below so a choice survives a
  # restart, and hydrated back into app env on boot (see `load_persisted/0`).
  @model_key :core_ai_active_model
  @reasoning_key :core_ai_reasoning_enabled
  @persist_model "core_ai_active_model"
  @persist_reasoning "core_ai_reasoning_enabled"

  # Selectable chat models, in display order (first = default). `provider` is
  # `:cloud` (Anthropic Claude, via the CoreAI cloud tier) or `:ollama` (a resident
  # local model). `reasoning: true` marks models that support Ollama's `think`
  # field (Qwen3). Add the 30B here if you ever want it selectable again.
  @models [
    %{
      tag: "claude",
      label: "Claude (cloud)",
      provider: :cloud,
      reasoning: false,
      describe:
        "Default. Anthropic Claude (claude-haiku-4-5) via API — highest-quality " <>
          "interpret/phrase. Private values are redacted to tokens before they leave " <>
          "the network; falls back to the local model, then the stub, if the API is down."
    },
    %{
      tag: "qwen3:14b",
      label: "Qwen3 14B",
      provider: :ollama,
      reasoning: true,
      describe:
        "Local. Newer generation, same family as the 30B. Runs with reasoning " <>
          "(thinking) OFF for interpret/phrase; the mode can be toggled below."
    },
    %{
      tag: "qwen2.5:14b-instruct",
      label: "Qwen2.5 14B",
      provider: :ollama,
      reasoning: false,
      describe: "Local. Fast, instruction-tuned generalist. No reasoning mode."
    }
  ]

  @doc "Every selectable model (full metadata maps, display order)."
  def all, do: @models

  @doc "Just the model tags."
  def tags, do: Enum.map(@models, & &1.tag)

  @doc """
  The boot default SELECTION: the configured `CORE_AI_MODEL` when it names a
  selectable model, otherwise the first listed model (Claude). A `CORE_AI_MODEL`
  that names a non-selectable local model (e.g. qwen3:30b) is treated as the local
  tier model (see `local_model/0`), not the selection — so the default is Claude
  and that model becomes the local/fallback engine.
  """
  def default do
    tag = config_model()
    if is_binary(tag) and tag != "" and tag in tags(), do: tag, else: hd(@models).tag
  end

  # The configured CORE_AI_MODEL (may be unset, a selectable tag, or a
  # non-selectable local model like qwen3:30b).
  defp config_model, do: Application.get_env(:tragar_ai, TragarAi.CoreAI, [])[:model]

  @doc """
  The local Ollama model tag for the local tier: the model the app calls when a
  local model is selected, and the fallback the loop uses when a cloud model
  (Claude) is active — so it degrades to the real local model, never straight to
  the stub. Uses `CORE_AI_MODEL` when it names a local model (any Ollama tag,
  including non-selectable ones such as qwen3:30b), else the first local model.
  """
  def local_model do
    case config_model() do
      tag when is_binary(tag) and tag != "" ->
        if provider(tag) == :ollama, do: tag, else: first_local_tag()

      _ ->
        first_local_tag()
    end
  end

  defp first_local_tag do
    case Enum.find(@models, &(&1.provider == :ollama)) do
      %{tag: tag} -> tag
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
      TragarAi.RuntimeSettings.put(@persist_model, tag)
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

  @doc "The inference provider for a tag — `:cloud` (Claude) or `:ollama` (local)."
  def provider(tag), do: field(tag, :provider, :ollama)

  @doc "Whether the active model runs on the cloud (Claude) provider."
  def cloud?, do: provider(get()) == :cloud

  @doc "The metadata map for a tag, or nil if unknown."
  def meta(tag), do: Enum.find(@models, &(&1.tag == tag))

  @doc "Whether the reasoning toggle is on (independent of the active model)."
  def reasoning_enabled?, do: Application.get_env(:tragar_ai, @reasoning_key, false)

  @doc "Turn the reasoning toggle on/off. Returns `{:ok, on}`."
  def set_reasoning_enabled(on) when is_boolean(on) do
    Application.put_env(:tragar_ai, @reasoning_key, on)
    TragarAi.RuntimeSettings.put(@persist_reasoning, to_string(on))
    {:ok, on}
  end

  @doc """
  Hydrate the runtime overrides from the durable store into application env, so a
  model / reasoning choice made before a restart is restored. Called once at boot
  after the Repo starts. Best-effort — a missing store leaves the configured
  defaults in place; a persisted model no longer offered is ignored.
  """
  def load_persisted do
    case TragarAi.RuntimeSettings.get(@persist_model) do
      tag when is_binary(tag) and tag != "" ->
        if tag in tags(), do: Application.put_env(:tragar_ai, @model_key, tag)

      _ ->
        :ok
    end

    case TragarAi.RuntimeSettings.get(@persist_reasoning) do
      "true" -> Application.put_env(:tragar_ai, @reasoning_key, true)
      "false" -> Application.put_env(:tragar_ai, @reasoning_key, false)
      _ -> :ok
    end

    :ok
  end

  @doc """
  Clear both runtime overrides (in-memory and durable), reverting to the
  configured defaults (Claude selection, reasoning off). Mainly for test isolation.
  """
  def reset do
    Application.delete_env(:tragar_ai, @model_key)
    Application.delete_env(:tragar_ai, @reasoning_key)
    TragarAi.RuntimeSettings.delete(@persist_model)
    TragarAi.RuntimeSettings.delete(@persist_reasoning)
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

  # Unload every other resident (local) model, then warm the chosen one if it's
  # local, in the background so the settings click returns immediately. Cloud
  # (Claude) has nothing to load/unload, and switching TO it frees the local
  # models from memory. Best-effort; the unload/preload calls no-op unless CoreAI
  # is in :ollama mode.
  defp swap_resident(tag) do
    Task.start(fn ->
      for other <- tags(), other != tag, provider(other) == :ollama do
        TragarAi.CoreAI.unload(other)
      end

      if provider(tag) == :ollama, do: TragarAi.CoreAI.preload(tag)
    end)

    :ok
  end
end
