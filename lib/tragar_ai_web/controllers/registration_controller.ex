defmodule TragarAiWeb.RegistrationController do
  @moduledoc """
  Partner-initiated access requests.

  `POST /api/v1/access-requests` (partner key only) with
  `{"account_reference": "...", "email": "..."}`. If the account exists and the
  email matches the account's authoritative contact, a magic link is emailed to
  the customer. The response is always `202 Accepted` with the same body,
  regardless of whether a match was found, to avoid account/email enumeration.
  """

  use TragarAiWeb, :controller

  alias TragarAi.Accounts.Registration

  def create(conn, params) do
    cond do
      conn.assigns.gateway_auth.scope != :partner ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "forbidden", message: "A partner API key is required."}})

      not valid_params?(params) ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            code: "invalid_arguments",
            message: "account_reference and email are required."
          }
        })

      true ->
        :ok = Registration.request_access(params["account_reference"], params["email"])

        conn
        |> put_status(:accepted)
        |> json(%{
          status: "accepted",
          message:
            "If the account and email match our records, an activation link has been emailed."
        })
    end
  end

  defp valid_params?(%{"account_reference" => ref, "email" => email})
       when is_binary(ref) and is_binary(email),
       do: ref != "" and email != ""

  defp valid_params?(_), do: false
end
