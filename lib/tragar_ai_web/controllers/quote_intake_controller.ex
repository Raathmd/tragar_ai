defmodule TragarAiWeb.QuoteIntakeController do
  @moduledoc """
  Endpoint Freshdesk calls to run a guided quote conversation.

  `POST /api/quotes/intake` with JSON:

      {"account": "ITD02", "ticket_id": "55", "message": "I want to ship 3 pallets",
       "requester_email": "buyer@acme.co.za"}

  The account is taken from the body (the Freshdesk integration supplies it).
  Each customer reply is a separate call with the same `ticket_id`; the response
  `reply` is the next question to post back, until `complete` is true.
  """

  use TragarAiWeb, :controller

  alias TragarAi.QuoteIntake.Server

  def intake(conn, params) do
    with {:ok, account} <- require_param(params, "account"),
         {:ok, ticket_id} <- require_param(params, "ticket_id") do
      input = %{
        ticket_id: to_string(ticket_id),
        account: to_string(account),
        message: params["message"] || "",
        requester_email: params["requester_email"]
      }

      case Server.handle(input) do
        {:ok, result} ->
          json(conn, result)

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    else
      {:missing, field} ->
        conn |> put_status(:bad_request) |> json(%{error: "#{field} is required"})
    end
  end

  defp require_param(params, field) do
    case params[field] do
      v when is_binary(v) and v != "" -> {:ok, v}
      v when is_integer(v) -> {:ok, v}
      _ -> {:missing, field}
    end
  end
end
