defmodule TragarAi.Dashboard do
  @moduledoc """
  Pub/sub for the live integration monitor. The flows broadcast when something
  changes (a ticket answered, a quote session advanced); `DashboardLive`
  subscribes and re-renders instantly — no polling.
  """
  @topic "dashboard"

  @doc "Subscribe the calling LiveView process to dashboard changes."
  def subscribe, do: Phoenix.PubSub.subscribe(TragarAi.PubSub, @topic)

  @doc "Notify monitors that a tracked flow changed."
  def broadcast, do: Phoenix.PubSub.broadcast(TragarAi.PubSub, @topic, :dashboard_changed)
end
