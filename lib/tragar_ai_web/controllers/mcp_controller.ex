defmodule TragarAiWeb.MCPController do
  @moduledoc """
  Minimal [Model Context Protocol](https://modelcontextprotocol.io) server over
  the Streamable HTTP transport (JSON-RPC 2.0 on a single `POST /mcp`).

  Implements the methods an MCP client needs to discover and call tools:

    * `initialize`
    * `notifications/initialized` (notification — no response)
    * `tools/list`
    * `tools/call`
    * `ping`

  Tools come from the shared `TragarAi.Tools` registry, so the same FreightWare
  capabilities exposed over REST are available to MCP-capable agents (Claude,
  etc.).
  """

  use TragarAiWeb, :controller

  alias TragarAi.Tools

  @protocol_version "2025-06-18"

  def rpc(conn, %{"jsonrpc" => "2.0", "method" => method} = body) do
    id = Map.get(body, "id")
    params = Map.get(body, "params", %{})

    case handle(method, params, conn) do
      :notification ->
        send_resp(conn, 202, "")

      {:result, result} ->
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

      {:error, code, message} ->
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => code, "message" => message}
        })
    end
  end

  def rpc(conn, _invalid) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32600, "message" => "Invalid Request"}
    })
  end

  # ── Methods ───────────────────────────────────────────────────────────────

  defp handle("initialize", params, _conn) do
    {:result,
     %{
       "protocolVersion" => negotiate_version(params),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "tragar-freightware-gateway", "version" => "1.0.0"}
     }}
  end

  defp handle("notifications/initialized", _params, _conn), do: :notification

  defp handle("ping", _params, _conn), do: {:result, %{}}

  defp handle("tools/list", _params, _conn) do
    tools =
      Enum.map(Tools.definitions(), fn t ->
        %{
          "name" => t.name,
          "description" => t.description,
          "inputSchema" => t.parameters
        }
      end)

    {:result, %{"tools" => tools}}
  end

  defp handle("tools/call", %{"name" => name} = params, conn) do
    args = Map.get(params, "arguments", %{})
    auth = conn.assigns.gateway_auth

    opts = [
      scope: auth.scope,
      account_reference: auth.account_reference,
      transport: :mcp,
      client: auth.client
    ]

    case Tools.call(name, args, opts) do
      {:ok, result} ->
        {:result, tool_result(result, false)}

      {:error, %{code: :unknown_tool, message: message}} ->
        {:error, -32602, message}

      {:error, %{message: message}} ->
        # Per MCP, tool execution errors are reported in the result with
        # isError: true (not as a JSON-RPC protocol error).
        {:result, tool_result(%{"error" => message}, true)}
    end
  end

  defp handle("tools/call", _params, _conn),
    do: {:error, -32602, "Invalid params: 'name' is required"}

  defp handle(method, _params, _conn),
    do: {:error, -32601, "Method not found: #{method}"}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp tool_result(map, is_error?) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(map)}],
      "structuredContent" => map,
      "isError" => is_error?
    }
  end

  defp negotiate_version(%{"protocolVersion" => v}) when is_binary(v), do: v
  defp negotiate_version(_), do: @protocol_version
end
