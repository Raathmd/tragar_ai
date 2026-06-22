defmodule Mix.Tasks.Tragar.FwAuth do
  @shortdoc "Check FreightWare (Dovetail) authentication from DOVETAIL_* env vars"
  @moduledoc """
  Verify FreightWare auth end to end. Reads credentials from env (never stored in
  the repo) and prints the session token on success or the FreightWare error.

      DOVETAIL_BASE_URL=http://tragar-db.dovetail.co.za:5001/WebServices/web \\
      DOVETAIL_USERNAME=TragarWeb DOVETAIL_PASSWORD=*** DOVETAIL_STATION=JHB \\
      mix tragar.fw_auth
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    cfg = Application.get_env(:tragar_ai, TragarAi.Dovetail.Client, [])
    missing = for k <- [:base_url, :username, :password, :station], is_nil(cfg[k]), do: k

    cond do
      missing != [] ->
        Mix.shell().error(
          "Missing config #{inspect(missing)} — set DOVETAIL_BASE_URL / DOVETAIL_USERNAME / " <>
            "DOVETAIL_PASSWORD / DOVETAIL_STATION."
        )

      true ->
        Mix.shell().info("→ #{cfg[:base_url]}  user=#{cfg[:username]}  station=#{cfg[:station]}")

        case TragarAi.Dovetail.Client.login() do
          {:ok, token} ->
            Mix.shell().info("OK — authenticated. token=#{String.slice(token, 0, 16)}…")

          {:error, reason} ->
            Mix.shell().error("FAILED — #{inspect(reason)}")
        end
    end
  end
end
