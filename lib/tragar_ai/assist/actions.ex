defmodule TragarAi.Assist.Actions do
  @moduledoc """
  The allowed actions per entity, split into **read** and **change**.

    * read actions — Elixir executes them (read-only fetch from the source).
    * change actions — the assistant does NOT execute them. The agent performs the
      change in the source application (FreightWare's quote builder / Dovetail),
      then returns and updates the ticket. The real source functions that back
      each change are named here (see `TragarAi.Freight`).

  Passed to the model (via `TragarAi.Assist.Tools`) so it can tell, from the
  question, whether something is a read it can request or a change to hand back
  to the agent.
  """

  @actions %{
    "quote" => %{
      read: [:quote_lookup],
      where: "FreightWare's quote builder",
      verbs: "amend, accept or reject",
      # TragarAi.Freight change functions.
      functions: ["create_quote", "accept_quote", "reject_quote"]
    },
    "waybill" => %{
      read: [:load_status, :eta, :pod, :track, :route],
      where: "FreightWare",
      verbs: "amend or re-book",
      functions: ["build_shipment"]
    },
    "invoice" => %{
      read: [:invoice],
      where: "Pastel",
      verbs: "adjust",
      functions: []
    }
  }

  @default %{where: "the source system", verbs: "amend", functions: []}

  @doc "The change action for an entity (where the agent does it + which source functions)."
  def change_for(entity), do: Map.get(@actions, to_string(entity), @default)

  @doc "All entities that have declared actions."
  def entities, do: Map.keys(@actions)

  def all, do: @actions
end
