defmodule TragarAiWeb.ToolController do
  @moduledoc """
  REST interface to the FreightWare tool gateway.

    * `GET  /api/v1/tools`        — list available tools and their schemas.
    * `POST /api/v1/tools/:name`  — invoke a tool; the JSON request body is the
      tool's arguments. Returns `{"result": ...}` or `{"error": ...}`.

  Calls are scoped to the caller's API key (`conn.assigns.gateway_auth`).
  """

  use TragarAiWeb, :controller

  alias TragarAi.Tools

  def index(conn, _params) do
    json(conn, %{tools: Tools.definitions()})
  end

  def invoke(conn, %{"name" => name} = params) do
    auth = conn.assigns.gateway_auth
    args = Map.drop(params, ["name"])

    opts = [
      scope: auth.scope,
      account_reference: auth.account_reference,
      transport: :rest,
      client: auth.client
    ]

    case Tools.call(name, args, opts) do
      {:ok, result} ->
        json(conn, %{result: result})

      {:error, %{code: code, message: message}} ->
        conn
        |> put_status(http_status(code))
        |> json(%{error: %{code: to_string(code), message: message}})
    end
  end

  defp http_status(:unknown_tool), do: :not_found
  defp http_status(:not_found), do: :not_found
  defp http_status(:forbidden), do: :forbidden
  defp http_status(:invalid_arguments), do: :bad_request
  defp http_status(_), do: :bad_gateway
end
