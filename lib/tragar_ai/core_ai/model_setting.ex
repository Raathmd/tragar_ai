defmodule TragarAi.CoreAI.ModelSetting do
  @moduledoc """
  Runtime selection of the active local chat model, plus a reasoning (thinking)
  toggle for models that support it.

  The selectable list is discovered LIVE from Ollama (`TragarAi.CoreAI.list_models/0`,
  i.e. `/api/tags`), so models added or removed on the box appear in Settings with
  no code change. `@meta` only enriches known tags with a nicer label / description
  and a reasoning-capability flag; unknown models are still selectable (label = the
  tag, reasoning inferred from the name).

  There is NO cloud/Claude option — every model is local (`provider: :ollama`).
  The external tier is removed for POPIA compliance (no freight/customer data may
  leave the box); see `TragarAi.CoreAI.Cloud`.

  Backed by application env so it can be flipped live without a restart, mirrored
  to the durable `RuntimeSettings` store, and hydrated back on boot
  (`load_persisted/0`). Selecting a model asks Ollama to unload the others
  (`keep_alive: 0`) and warm the chosen one (`keep_alive: -1`) — this 32 GB box
  shares memory with the live app, so only one ~14B model stays resident.
  """

  alias TragarAi.CoreAI

  @model_key :core_ai_active_model
  @reasoning_key :core_ai_reasoning_enabled
  @persist_model "core_ai_active_model"
  @persist_reasoning "core_ai_reasoning_enabled"

  # Metadata for KNOWN local models — label, reasoning capability, description.
  # This does NOT limit what's selectable (that comes live from Ollama); it only
  # enriches these tags. No cloud/Claude entry — the external tier is removed.
  @meta %{
    "qwen3:14b" => %{
      label: "Qwen3 14B",
      reasoning: true,
      describe:
        "Local. Newer generation, same family as the 30B. Runs with reasoning " <>
          "(thinking) OFF for interpret/phrase; the mode can be toggled below."
    },
    "qwen2.5:14b-instruct" => %{
      label: "Qwen2.5 14B",
      reasoning: false,
      describe: "Local. Fast, instruction-tuned generalist. No reasoning mode."
    }
  }

  # Used only when Ollama's model list can't be read (e.g. it's momentarily down),
  # so Settings and validation still have something sensible to show.
  @fallback_tags ["qwen3:14b", "qwen2.5:14b-instruct"]

  @doc """
  Every selectable model as a full metadata map, in the order Ollama lists them:
  `%{tag, label, provider: :ollama, reasoning, describe}`. Discovered live from
  Ollama; falls back to the known tags when Ollama can't be reached.
  """
  def all do
    case CoreAI.list_models() do
      [] -> Enum.map(@fallback_tags, &model_map/1)
      tags -> Enum.map(tags, &model_map/1)
    end
  end

  @doc "Just the selectable model tags (live from Ollama, else the known fallback)."
  def tags, do: Enum.map(all(), & &1.tag)

  defp model_map(tag) do
    m = Map.get(@meta, tag, %{})

    %{
      tag: tag,
      label: Map.get(m, :label, tag),
      provider: :ollama,
      reasoning: Map.get(m, :reasoning, reasoning_by_name?(tag)),
      describe: Map.get(m, :describe, "Local Ollama model.")
    }
  end

  # Reasoning (thinking) capability for models we don't have explicit metadata for:
  # inferred from the tag name (Qwen3 / DeepSeek-R1 / *-reasoning / *-think).
  @reasoning_hints ["qwen3", "r1", "reason", "think"]
  defp reasoning_by_name?(tag) do
    t = String.downcase(to_string(tag))
    Enum.any?(@reasoning_hints, &String.contains?(t, &1))
  end

  @doc """
  The boot default SELECTION: the configured `CORE_AI_MODEL` when set, otherwise
  the first known fallback model. Cheap (no Ollama call) — it's read on every
  dispatch via `get/0`.
  """
  def default do
    tag = config_model()
    if is_binary(tag) and tag != "", do: tag, else: hd(@fallback_tags)
  end

  defp config_model, do: Application.get_env(:tragar_ai, TragarAi.CoreAI, [])[:model]

  @doc """
  The local Ollama model tag for the local tier: `CORE_AI_MODEL` when set (any
  Ollama tag, including non-selectable ones like qwen3:30b), else the first known
  local model. Every model is local now, so this is just the configured/default tag.
  """
  def local_model do
    case config_model() do
      tag when is_binary(tag) and tag != "" -> tag
      _ -> hd(@fallback_tags)
    end
  end

  @doc "The active model tag."
  def get, do: Application.get_env(:tragar_ai, @model_key, default())

  @doc """
  Set the active model at runtime. Accepts any model Ollama currently offers.
  Returns `{:ok, tag}` or `{:error, :unknown_model}`. Triggers a background
  load-one/unload-others swap so only the chosen model stays resident.
  """
  def set(tag) when is_binary(tag) do
    if tag != "" and tag in tags() do
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
  def label(tag), do: model_map(tag).label

  @doc "One-line description of a model tag."
  def describe(tag), do: model_map(tag).describe

  @doc "Whether a model supports the reasoning (thinking) mode."
  def reasoning_capable?(tag), do: model_map(tag).reasoning == true

  @doc "The inference provider for a tag — always `:ollama` (the cloud tier is removed)."
  def provider(_tag), do: :ollama

  @doc "Whether the active model runs on the cloud provider — always false (removed)."
  def cloud?, do: false

  @doc "The metadata map for a tag."
  def meta(tag), do: model_map(tag)

  @doc "Whether the reasoning toggle is on (independent of the active model)."
  def reasoning_enabled?, do: Application.get_env(:tragar_ai, @reasoning_key, false)

  @doc "Turn the reasoning toggle on/off. Returns `{:ok, on}`."
  def set_reasoning_enabled(on) when is_boolean(on) do
    Application.put_env(:tragar_ai, @reasoning_key, on)
    TragarAi.RuntimeSettings.put(@persist_reasoning, to_string(on))
    {:ok, on}
  end

  @doc """
  Hydrate the runtime overrides from the durable store into application env on
  boot. The persisted model is restored as-is (it was valid when chosen; if it's
  since been removed from Ollama the dispatch degrades gracefully) rather than
  validated against a possibly-not-yet-ready Ollama.
  """
  def load_persisted do
    case TragarAi.RuntimeSettings.get(@persist_model) do
      tag when is_binary(tag) and tag != "" ->
        Application.put_env(:tragar_ai, @model_key, tag)

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
  configured defaults. Mainly for test isolation.
  """
  def reset do
    Application.delete_env(:tragar_ai, @model_key)
    Application.delete_env(:tragar_ai, @reasoning_key)
    TragarAi.RuntimeSettings.delete(@persist_model)
    TragarAi.RuntimeSettings.delete(@persist_reasoning)
    :ok
  end

  @doc """
  Whether generations should run with thinking on right now: the toggle is on AND
  the active model supports reasoning. `model_thinks?/1` answers for a named model.
  """
  def thinking_active?, do: model_thinks?(get())

  def model_thinks?(tag), do: reasoning_enabled?() and reasoning_capable?(tag)

  # Unload every other resident model, then warm the chosen one — in the background
  # so the settings click returns immediately. Best-effort; no-ops unless CoreAI is
  # in :ollama mode.
  defp swap_resident(tag) do
    Task.start(fn ->
      for other <- tags(), other != tag do
        CoreAI.unload(other)
      end

      CoreAI.preload(tag)
    end)

    :ok
  end
end
