defmodule TragarAi.Gateway do
  @moduledoc """
  Gateway domain — the AI-facing side of the application.

  Owns the `ToolCall` audit resource: a record of every tool invocation made by
  an AI agent (Freddy or otherwise) through the REST or MCP interfaces. Useful
  for observability, debugging, and rate/abuse analysis.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Gateway.ToolCall do
      define :log_tool_call, action: :create
      define :list_tool_calls, action: :read
    end
  end
end
