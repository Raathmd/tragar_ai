defmodule TragarAiWeb.OpenAPIController do
  @moduledoc """
  Serves an OpenAPI 3.1 document describing the tool gateway, generated from the
  `TragarAi.Tools` registry. Import this into Freshdesk Freddy as custom
  actions, or into any agent that consumes OpenAPI.
  """

  use TragarAiWeb, :controller

  alias TragarAi.Tools

  def spec(conn, _params) do
    json(conn, build(base_url(conn)))
  end

  defp build(server_url) do
    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "Tragar FreightWare Gateway",
        "version" => "1.0.0",
        "description" =>
          "AI-callable tools wrapping Tragar's FreightWare (Dovetail) system. " <>
            "FreightWare is the source of truth for shipment status; these tools let " <>
            "an AI agent answer customer status, tracking, POD and quote questions."
      },
      "servers" => [%{"url" => server_url}],
      "components" => %{
        "securitySchemes" => %{
          "bearerAuth" => %{"type" => "http", "scheme" => "bearer"}
        }
      },
      "security" => [%{"bearerAuth" => []}],
      "paths" => paths()
    }
  end

  defp paths do
    Tools.list()
    |> Map.new(fn tool ->
      {"/api/v1/tools/#{tool.name}",
       %{
         "post" => %{
           "operationId" => tool.name,
           "summary" => tool.description,
           "description" => tool.description,
           "requestBody" => %{
             "required" => true,
             "content" => %{
               "application/json" => %{"schema" => tool.parameters}
             }
           },
           "responses" => %{
             "200" => %{
               "description" => "Tool result",
               "content" => %{
                 "application/json" => %{
                   "schema" => %{
                     "type" => "object",
                     "properties" => %{"result" => %{"type" => "object"}}
                   }
                 }
               }
             },
             "400" => %{"description" => "Invalid arguments"},
             "401" => %{"description" => "Unauthorized"},
             "502" => %{"description" => "Upstream FreightWare error"}
           }
         }
       }}
    end)
  end

  defp base_url(conn) do
    "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"
end
