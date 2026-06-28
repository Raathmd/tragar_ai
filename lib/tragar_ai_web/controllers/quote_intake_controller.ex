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

  alias TragarAi.QuoteIntake
  alias TragarAi.QuoteIntake.Server

  @doc """
  The machine-readable quote workflow — a tool any caller can fetch to learn the
  steps, parameters and allowed values for taking a customer through creating a
  quote.
  """
  def workflow(conn, _params), do: json(conn, QuoteIntake.workflow())

  def intake(conn, params) do
    # The account is NOT accepted from the body — the Server derives the
    # requester's entitled account(s) from Freshdesk using the ticket_id.
    case require_param(params, "ticket_id") do
      {:ok, ticket_id} ->
        input = %{
          ticket_id: to_string(ticket_id),
          message: params["message"] || "",
          requester_email: params["requester_email"]
        }

        case Server.handle(input) do
          {:ok, result} ->
            json(conn, result)

          {:error, reason} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
        end

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
