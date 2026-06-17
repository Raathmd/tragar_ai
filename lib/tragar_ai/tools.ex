defmodule TragarAi.Tools do
  @moduledoc """
  The AI-callable tool surface over FreightWare (Dovetail), **account-scoped**.

  This module is the single source of truth for the tools exposed to AI agents;
  both the REST/OpenAPI interface (`TragarAiWeb.ToolController`) and the MCP
  interface (`TragarAiWeb.MCPController`) are generated from the registry here.

  Customer-data tools require an **account-scoped** API key and only ever return
  shipments belonging to that account (a mismatch is reported as `:not_found`,
  never as another account's data). Reads go through `TragarAi.Logistics.Cache`,
  so they hit Elixir's cache first and FreightWare only on a miss.

  Each tool is a map with `:name`, `:description`, `:parameters` (JSON Schema)
  and a `:handler` of arity 2 — `fn args, context -> {:ok, map} | {:error, _}`.
  The `context` carries `:scope` and `:account_reference` from the caller's key.
  """

  alias TragarAi.Dovetail
  alias TragarAi.Gateway
  alias TragarAi.Logistics.Cache
  alias TragarAi.Tools.Normalize

  require Logger

  # ── Registry ──────────────────────────────────────────────────────────────

  @tools [
    %{
      name: "track_shipment",
      description:
        "Track one of YOUR shipments by its FreightWare waybill number. Returns " <>
          "the current status, the full list of tracking events, and " <>
          "proof-of-delivery details if delivered. Primary tool for answering " <>
          "'where is my delivery / what is the status' questions. Only returns the " <>
          "waybill if it belongs to your account.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "waybill_number" => %{
            "type" => "string",
            "description" => "The waybill (consignment) number to track, e.g. \"WB1234567\"."
          }
        },
        "required" => ["waybill_number"],
        "additionalProperties" => false
      },
      handler: &__MODULE__.track_shipment/2
    },
    %{
      name: "list_my_shipments",
      description:
        "List the shipments cached for your account, with their current status. " <>
          "Use to answer 'show me my recent deliveries / open shipments'.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      },
      handler: &__MODULE__.list_my_shipments/2
    },
    %{
      name: "list_service_types",
      description:
        "List the freight service types available in FreightWare (e.g. overnight, " <>
          "economy), with their codes and descriptions.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      },
      handler: &__MODULE__.list_service_types/2
    },
    %{
      name: "get_quick_quote",
      description:
        "Get an instant freight rate quote for a shipment between two postal " <>
          "codes for your account. Returns the available rates by service type.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "service_type" => %{"type" => "string"},
          "collection_postal_code" => %{"type" => "string"},
          "delivery_postal_code" => %{"type" => "string"},
          "items" => %{
            "type" => "array",
            "description" => "Line items being shipped.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "quantity" => %{"type" => "integer"},
                "weight" => %{"type" => "number"},
                "length" => %{"type" => "number"},
                "width" => %{"type" => "number"},
                "height" => %{"type" => "number"}
              },
              "required" => ["quantity", "weight"]
            }
          }
        },
        "required" => ["collection_postal_code", "delivery_postal_code", "items"],
        "additionalProperties" => true
      },
      handler: &__MODULE__.get_quick_quote/2
    }
  ]

  @tools_by_name Map.new(@tools, &{&1.name, &1})

  @doc "All tool definitions (including handlers)."
  def list, do: @tools

  @doc "Public-facing tool definitions: name, description, parameters only."
  def definitions, do: Enum.map(@tools, &Map.take(&1, [:name, :description, :parameters]))

  @doc "Fetch a single tool definition by name."
  def fetch(name), do: Map.fetch(@tools_by_name, name)

  # ── Dispatch ──────────────────────────────────────────────────────────────

  @doc """
  Invoke a tool by name with a map of arguments.

  `opts`:
    * `:scope` — `:account` | `:partner` (from the caller's key)
    * `:account_reference` — the caller's account (account-scoped keys)
    * `:transport` — `:rest` | `:mcp` (audit only)
    * `:client` — caller identifier (audit only)

  Returns `{:ok, result_map}` or `{:error, %{code: atom, message: binary}}`.
  """
  @spec call(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, %{code: atom(), message: String.t()}}
  def call(name, args, opts \\ []) when is_map(args) do
    case fetch(name) do
      :error ->
        {:error, %{code: :unknown_tool, message: "Unknown tool: #{name}"}}

      {:ok, tool} ->
        ctx = %{
          scope: Keyword.get(opts, :scope, :partner),
          account_reference: Keyword.get(opts, :account_reference)
        }

        started = System.monotonic_time(:millisecond)
        result = run(tool, args, ctx)
        duration = System.monotonic_time(:millisecond) - started
        audit(name, args, result, duration, opts)
        result
    end
  end

  defp run(tool, args, ctx) do
    tool.handler.(args, ctx) |> normalize_result()
  rescue
    e ->
      Logger.error("Tool #{tool.name} crashed: #{Exception.message(e)}")
      {:error, %{code: :exception, message: Exception.message(e)}}
  end

  defp normalize_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_result({:error, %{code: _, message: _} = err}), do: {:error, err}

  defp normalize_result({:error, :not_found}),
    do: {:error, %{code: :not_found, message: "Not found for this account."}}

  defp normalize_result({:error, msg}) when is_binary(msg),
    do: {:error, %{code: :tool_error, message: msg}}

  defp normalize_result({:error, reason}),
    do: {:error, %{code: :upstream_error, message: inspect(reason)}}

  defp audit(name, args, result, duration, opts) do
    {outcome, error} =
      case result do
        {:ok, _} -> {:ok, nil}
        {:error, %{message: msg}} -> {:error, msg}
      end

    Gateway.log_tool_call(%{
      tool: name,
      transport: Keyword.get(opts, :transport, :rest),
      client: Keyword.get(opts, :client),
      arguments: args,
      outcome: outcome,
      duration_ms: duration,
      error: error
    })
  rescue
    e -> Logger.warning("Failed to audit tool call #{name}: #{Exception.message(e)}")
  end

  # ── Tool handlers ─────────────────────────────────────────────────────────

  @doc false
  def track_shipment(%{"waybill_number" => waybill}, ctx) when is_binary(waybill) do
    with {:ok, ref} <- require_account(ctx) do
      Cache.fetch(waybill, ref)
    end
  end

  def track_shipment(_, _),
    do: {:error, %{code: :invalid_arguments, message: "waybill_number is required"}}

  @doc false
  def list_my_shipments(_args, ctx) do
    with {:ok, ref} <- require_account(ctx),
         {:ok, shipments} <- Cache.list(ref) do
      {:ok, %{"shipments" => shipments}}
    end
  end

  @doc false
  def list_service_types(_args, _ctx) do
    with {:ok, data} <- Dovetail.Client.service_types() do
      {:ok, %{"service_types" => Normalize.service_types(data)}}
    end
  end

  @doc false
  def get_quick_quote(args, ctx) when is_map(args) do
    with {:ok, ref} <- require_account(ctx) do
      request = args |> Map.put("account_reference", ref) |> Normalize.quote_request()

      with {:ok, data} <- Dovetail.Client.quick_quote(request) do
        {:ok, %{"rates" => Normalize.rates(data)}}
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Customer-data tools require an account-scoped key.
  defp require_account(%{scope: :account, account_reference: ref}) when is_binary(ref),
    do: {:ok, ref}

  defp require_account(_),
    do:
      {:error,
       %{code: :forbidden, message: "This tool requires a customer (account-scoped) API key."}}
end
