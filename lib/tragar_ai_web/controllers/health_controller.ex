defmodule TragarAiWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe for Docker + the deploy health gate. Unauthenticated;
  verifies the app is up and the database is reachable.
  """
  use TragarAiWeb, :controller

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(TragarAi.Repo, "SELECT 1", []) do
      {:ok, _} -> send_resp(conn, 200, "ok")
      _ -> send_resp(conn, 503, "db_unavailable")
    end
  end
end
