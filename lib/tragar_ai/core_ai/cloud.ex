defmodule TragarAi.CoreAI.Cloud do
  @moduledoc """
  Cloud (Anthropic Claude) tier — PERMANENTLY DISABLED for POPIA compliance.

  No freight or customer data may leave this box, so the external-model tier is
  removed. This module is a hard-off stub:

    * `enabled?/0` is always `false` — every cloud attempt in `TragarAi.CoreAI`
      gates on it, so `order/2` degrades to local Ollama only and no cloud
      dispatch branch is ever built.
    * `chat/2` never makes an outbound request — it returns `{:error,
      :cloud_disabled}` even if something calls it directly.

  There is intentionally NO Anthropic client, URL, key, or HTTP call here. Do not
  re-enable — freight/customer data must never reach a third-party API.
  """

  @doc "Always false — the cloud tier is removed (POPIA: no data leaves the box)."
  @spec enabled?() :: boolean()
  def enabled?, do: false

  @doc "Disabled — never calls an external API; the cloud tier is removed."
  @spec chat([map()], keyword()) :: {:error, :cloud_disabled}
  def chat(_messages, _opts \\ []), do: {:error, :cloud_disabled}
end
