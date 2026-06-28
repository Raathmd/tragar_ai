defmodule TragarAiWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server exposing the guided quote workflow as tools
  an MCP client can discover and call. JSON-RPC 2.0 over HTTP at the conventional
  `POST /mcp` (root path; runs through the `:api` pipeline gates).

  Three gates protect it:

  1. **Bearer** — the whole `/api` surface (this included) requires the bearer
     token (`TragarAiWeb.Plugs.ApiAuth`). Answers "is the caller Freshworks?".
  2. **Session** — every call except `initialize` must carry a `Mcp-Session-Id`
     issued by `initialize` (a signed, expiring token). So a caller can only
     invoke tools after a proper MCP handshake.
  3. **Requester/email** — the `quote_intake` tool derives the account from the
     ticket's Freshdesk requester and refuses an unlinked email.

  Note: responses are plain `application/json` (no SSE). That's spec-compliant
  for request/response tool calls.
  """

  use TragarAiWeb, :controller

  alias TragarAi.Assist.Scope
  alias TragarAi.QuoteIntake
  alias TragarAi.QuoteIntake.Server

  @protocol "2025-06-18"
  @session_salt "mcp_session"
  @session_max_age 60 * 60 * 8

  # JSON-RPC batch (array body arrives as %{"_json" => [...]}).
  def rpc(conn, %{"_json" => batch}) when is_list(batch) do
    {conn, responses} =
      Enum.reduce(batch, {conn, []}, fn req, {c, acc} ->
        case dispatch(c, req) do
          {:reply, c2, resp} -> {c2, [resp | acc]}
          {:noreply, c2} -> {c2, acc}
        end
      end)

    json(conn, Enum.reverse(responses))
  end

  def rpc(conn, req) do
    case dispatch(conn, req) do
      {:reply, conn, resp} -> json(conn, resp)
      {:noreply, conn} -> send_resp(conn, 202, "")
    end
  end

  # ── JSON-RPC dispatch ─────────────────────────────────────────────────────────

  defp dispatch(conn, %{"method" => method} = req) do
    id = req["id"]
    params = req["params"] || %{}

    case method(conn, method, params) do
      {:ok, conn, result} -> {:reply, conn, ok(id, result)}
      {:error, conn, code, message} -> {:reply, conn, err(id, code, message)}
      {:notification, conn} -> {:noreply, conn}
    end
  end

  defp dispatch(conn, _bad), do: {:reply, conn, err(nil, -32600, "Invalid Request")}

  defp method(conn, "initialize", _params) do
    session = Phoenix.Token.sign(conn, @session_salt, System.unique_integer([:positive]))

    {:ok, put_resp_header(conn, "mcp-session-id", session),
     %{
       "protocolVersion" => @protocol,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "tragar-quote-intake", "version" => "1.0.0"}
     }}
  end

  defp method(conn, "notifications/" <> _, _), do: {:notification, conn}

  defp method(conn, "ping", _params), do: with_session(conn, fn conn -> {:ok, conn, %{}} end)

  defp method(conn, "tools/list", _params),
    do: with_session(conn, fn conn -> {:ok, conn, %{"tools" => tools()}} end)

  defp method(conn, "tools/call", params),
    do:
      with_session(conn, fn conn ->
        call_tool(conn, params["name"], params["arguments"] || %{})
      end)

  defp method(conn, _other, _params), do: {:error, conn, -32601, "Method not found"}

  # ── Session gate ──────────────────────────────────────────────────────────────

  defp with_session(conn, fun) do
    case get_req_header(conn, "mcp-session-id") do
      [sid] ->
        case Phoenix.Token.verify(conn, @session_salt, sid, max_age: @session_max_age) do
          {:ok, _} -> fun.(conn)
          _ -> {:error, conn, -32000, "Invalid or expired session — call initialize first"}
        end

      _ ->
        {:error, conn, -32000, "Missing Mcp-Session-Id — call initialize first"}
    end
  end

  # ── Tools ─────────────────────────────────────────────────────────────────────

  # Entity arguments a read tool may take (whitelist — avoids atom injection).
  @entity_keys ~w(waybill account quote ticket_id)

  defp tools, do: quote_tools() ++ read_tools()

  defp quote_tools do
    [
      %{
        "name" => "quote_workflow",
        "description" =>
          "Get the guided quote-creation workflow: the ordered steps, parameters and the live FreightWare service types.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "required" => []}
      },
      %{
        "name" => "quote_intake",
        "description" =>
          "Run one turn of the guided quote conversation for a Freshdesk ticket. The account is derived from the ticket's requester; an email not linked to an account is refused. Returns the next question (or summary/result) in `reply`.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "ticket_id" => %{"type" => "string", "description" => "Freshdesk ticket id"},
            "message" => %{"type" => "string", "description" => "The customer's latest message"}
          },
          "required" => ["ticket_id"]
        }
      }
    ]
  end

  # The read/fact tools, generated from the single source of truth
  # (`Assist.Tools.schema`): waybill status, ETA, POD, tracking, quote lookup,
  # account/invoice, service types, etc. Each returns the live facts.
  defp read_tools do
    for t <- TragarAi.Assist.Tools.schema(), t["action"] == "read" do
      %{
        "name" => t["name"],
        "description" => "[#{t["source"]}] #{t["description"]}",
        "inputSchema" => put_scope_arg(t["parameters"])
      }
    end
  end

  # Account-scoped facts need a validated scope: a ticket_id we resolve to the
  # requester's account(s) via Freshdesk (never a caller-supplied account).
  defp put_scope_arg(schema) do
    put_in(schema, ["properties", "ticket_id"], %{
      "type" => "string",
      "description" =>
        "Freshdesk ticket id — required to read account-scoped facts (waybill/quote/invoice)."
    })
  end

  defp read_tool_names, do: Enum.map(read_tools(), & &1["name"])

  defp call_tool(conn, "quote_workflow", _args),
    do: {:ok, conn, tool_text(Jason.encode!(QuoteIntake.workflow()))}

  defp call_tool(conn, "quote_intake", %{"ticket_id" => tid} = args) when tid not in [nil, ""] do
    input = %{
      ticket_id: to_string(tid),
      message: args["message"] || "",
      requester_email: args["requester_email"]
    }

    case Server.handle(input) do
      {:ok, result} ->
        structured = Map.take(result, [:status, :complete, :account, :rate, :quote_number])
        {:ok, conn, tool_text(result.reply, structured)}

      {:error, reason} ->
        {:ok, conn, tool_error("Quote intake failed: #{inspect(reason)}")}
    end
  end

  defp call_tool(conn, "quote_intake", _args),
    do: {:ok, conn, tool_error("ticket_id is required")}

  defp call_tool(conn, name, args) do
    if name in read_tool_names() do
      run_read_tool(conn, name, args)
    else
      {:error, conn, -32602, "Unknown tool: #{name}"}
    end
  end

  # Execute a read tool: fetch the live fact and enforce the validated account
  # scope (from the ticket_id) — facts off the requester's account are refused.
  defp run_read_tool(conn, name, args) do
    intent = String.to_existing_atom(name)
    entities = entities_from(args)
    accounts = authorized_accounts(args)

    cond do
      Map.has_key?(entities, :account) and
          not Scope.account_allowed?(entities[:account], accounts) ->
        {:ok, conn, tool_error("Not authorized for that account.")}

      true ->
        case TragarAi.Adapters.fetch(intent, entities) do
          {:ok, facts} ->
            if Scope.within?(facts, accounts) do
              {:ok, conn, tool_text(Jason.encode!(facts), facts)}
            else
              {:ok, conn,
               tool_error(
                 "Not authorized: that record is outside the ticket's account (pass a ticket_id)."
               )}
            end

          {:error, reason} ->
            {:ok, conn, tool_error("#{name}: #{inspect(reason)}")}
        end
    end
  end

  defp authorized_accounts(args) do
    case args["ticket_id"] do
      tid when is_binary(tid) and tid != "" ->
        case TragarAi.Freshdesk.accounts_for_requester(tid) do
          {:ok, accounts} when is_list(accounts) -> accounts
          _ -> []
        end

      _ ->
        []
    end
  end

  defp entities_from(args) do
    for {k, v} <- args, k in @entity_keys, is_binary(v), into: %{} do
      {String.to_existing_atom(k), v}
    end
  end

  # ── Shapes ────────────────────────────────────────────────────────────────────

  defp tool_text(text, structured \\ nil) do
    base = %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
    if structured, do: Map.put(base, "structuredContent", structured), else: base
  end

  defp tool_error(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}

  defp ok(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp err(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
