defmodule TragarAiWeb.ArchitectureLive do
  @moduledoc """
  A read-only tour of the application's design — for onboarding, demos and
  keeping the mental model honest. Nothing here is persisted or editable; every
  section is rendered **live from the code that actually runs**:

    * source systems ← `TragarAi.Adapters`
    * domain entities & their cross-source fan-out ← `TragarAi.Assist.Entities`
    * the capability catalogue the model is handed ← `TragarAi.Assist.Tools`
    * change actions ← `TragarAi.Assist.Actions`
    * the guided-quote slots ← `TragarAi.QuoteIntake.Flow`

  So the page can't drift from the system it describes — change an adapter's
  capabilities or add an entity and this diagram updates itself.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Adapters
  alias TragarAi.Assist.{Actions, Entities, Tools}
  alias TragarAi.QuoteIntake.Flow

  # Wired today (per `TragarAi.Adapters` moduledoc); the other adapters declare
  # their capabilities and return `{:error, :not_available}` until access is
  # provisioned. Kept here (not in the adapters) because "connected" is an
  # operational fact, not a property of the port.
  @connected ~w(FreightWare Freshdesk)

  # The safe loop, in order. Each step names who owns it — the model interprets
  # and phrases; Elixir validates, fetches and (via the agent) relays.
  @loop [
    %{step: "Interpret", owner: "Core AI", note: "free text → structured request"},
    %{step: "Validate", owner: "Elixir", note: "allowed? required entities? permitted?"},
    %{step: "Fetch", owner: "Adapters", note: "read-only, from the source of truth"},
    %{step: "Phrase", owner: "Core AI", note: "facts → customer-ready draft"},
    %{step: "Relay", owner: "Agent", note: "reviews, edits, sends"}
  ]

  # The user-facing surfaces (internal LiveViews) and the machine surfaces
  # (Freshdesk-facing REST + the MCP server). Descriptive and stable — kept as a
  # narrative here rather than reflected out of the router.
  @internal_surfaces [
    %{
      name: "Dashboard",
      path: "/",
      note: "Integration monitor — ticket answers & quote sessions, with response times."
    },
    %{
      name: "Console",
      path: "/console",
      note: "Support-assist console — surface facts, draft a reply, relay to the customer."
    },
    %{
      name: "Architecture",
      path: "/architecture",
      note: "This page — a live tour of the design."
    },
    %{
      name: "Admin",
      path: "/admin",
      note: "AshAdmin — browse persisted resources (dev only until real auth)."
    }
  ]

  @api_surfaces [
    %{
      verb: "GET",
      path: "/api/quotes/workflow",
      note: "The guided-quote workflow descriptor (+ live service types)."
    },
    %{
      verb: "POST",
      path: "/api/quotes/intake",
      note: "One customer message in a ticket → the next quote question."
    },
    %{
      verb: "POST",
      path: "/api/tickets/answer",
      note: "Freshdesk ticket → interpret → fetch → answer as a private note."
    },
    %{verb: "POST", path: "/mcp", note: "MCP (JSON-RPC) server registered in Freshdesk."}
  ]

  @impl true
  def mount(_params, _session, socket) do
    catalog = Tools.catalog()
    by_intent = Map.new(catalog, &{&1.intent, &1})

    {:ok,
     assign(socket,
       page_title: "Architecture",
       loop: @loop,
       internal_surfaces: @internal_surfaces,
       api_surfaces: @api_surfaces,
       systems: systems(),
       entities: entities(by_intent),
       catalog: Enum.sort_by(catalog, &to_string(&1.intent)),
       changes: change_actions(),
       quote_slots: quote_slots(),
       counts: counts(catalog)
     )}
  end

  # ── Data (all pure reads from the running modules) ───────────────────────────

  defp systems do
    for mod <- Adapters.adapters() do
      name = mod.name()

      %{
        name: name,
        connected: name in @connected,
        capabilities: mod.capabilities() |> Enum.map(&to_string/1) |> Enum.sort()
      }
    end
    |> Enum.sort_by(&{not &1.connected, &1.name})
  end

  defp entities(by_intent) do
    for {entity, %{param: param, capabilities: caps}} <- Entities.all() do
      %{
        entity: entity,
        param: param,
        capabilities: Enum.map(caps, fn c -> by_intent[c] || bare_cap(c) end)
      }
    end
    |> Enum.sort_by(&to_string(&1.entity))
  end

  defp bare_cap(intent),
    do: %{intent: intent, source: source_of(intent), required: [], description: ""}

  defp source_of(intent) do
    case Adapters.adapter_for(intent) do
      nil -> nil
      mod -> mod.name()
    end
  end

  defp change_actions do
    for {entity, a} <- Actions.all() do
      %{
        entity: entity,
        where: a.where,
        verbs: a.verbs,
        functions: a.functions
      }
    end
    |> Enum.sort_by(& &1.entity)
  end

  defp quote_slots do
    for key <- Flow.slot_keys(), do: %{key: key, question: Flow.question(key)}
  end

  defp counts(catalog) do
    systems = Adapters.adapters()

    %{
      systems: length(systems),
      connected: Enum.count(systems, &(&1.name() in @connected)),
      capabilities: length(catalog),
      entities: map_size(Entities.all())
    }
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 lg:p-6 space-y-8 max-w-6xl mx-auto">
      <Layouts.app_nav active={:architecture} flash={@flash} current_user={@current_user} />

      <header class="space-y-1">
        <h1 class="text-2xl font-semibold">Tragar · Architecture</h1>
        <p class="text-sm text-base-content/70 max-w-3xl">
          A support-assist layer over Tragar's freight operations. The model
          <strong>interprets</strong>
          a question and <strong>phrases</strong>
          the answer; Elixir <strong>validates</strong>
          and <strong>fetches</strong>
          the fact from whichever system owns it. The model is an interpreter —
          never the authority on a fact, and never touching a source directly.
        </p>
      </header>

      <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
        <div class="stat">
          <div class="stat-title">Source systems</div>
          <div class="stat-value text-3xl">{@counts.systems}</div>
          <div class="stat-desc">{@counts.connected} connected today</div>
        </div>
        <div class="stat">
          <div class="stat-title">Capabilities</div>
          <div class="stat-value text-3xl">{@counts.capabilities}</div>
          <div class="stat-desc">read tools the model may name</div>
        </div>
        <div class="stat">
          <div class="stat-title">Domain entities</div>
          <div class="stat-value text-3xl">{@counts.entities}</div>
          <div class="stat-desc">harmonised across sources</div>
        </div>
        <div class="stat">
          <div class="stat-title">Surfaces</div>
          <div class="stat-value text-3xl">{length(@internal_surfaces)}</div>
          <div class="stat-desc">+ {length(@api_surfaces)} machine endpoints</div>
        </div>
      </div>

      <%!-- ── The safe loop ─────────────────────────────────────────────────── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">The safe loop</h2>
        <p class="text-sm text-base-content/60">Every question travels the same path.</p>

        <div class="flex flex-wrap items-stretch gap-2">
          <div :for={{s, i} <- Enum.with_index(@loop)} class="contents">
            <div class="card border border-base-300 bg-base-100 grow basis-40">
              <div class="card-body p-3 gap-1">
                <div class="flex items-center gap-2">
                  <span class="badge badge-sm badge-neutral">{i + 1}</span>
                  <span class="font-semibold">{s.step}</span>
                </div>
                <span class={"badge badge-xs w-fit " <> owner_class(s.owner)}>{s.owner}</span>
                <p class="text-xs text-base-content/60">{s.note}</p>
              </div>
            </div>
            <div
              :if={i < length(@loop) - 1}
              class="hidden self-center text-xl text-base-content/30 lg:block"
            >
              →
            </div>
          </div>
        </div>
      </section>

      <%!-- ── Surfaces ──────────────────────────────────────────────────────── --%>
      <section class="grid gap-6 md:grid-cols-2">
        <div class="space-y-3">
          <h2 class="text-lg font-semibold">Interfaces (people)</h2>
          <div :for={s <- @internal_surfaces} class="flex items-baseline gap-3">
            <code class="badge badge-sm badge-outline shrink-0">{s.path}</code>
            <div>
              <span class="font-medium">{s.name}</span>
              <p class="text-xs text-base-content/60">{s.note}</p>
            </div>
          </div>
        </div>

        <div class="space-y-3">
          <h2 class="text-lg font-semibold">Endpoints (machines)</h2>
          <div :for={s <- @api_surfaces} class="flex items-baseline gap-3">
            <code class="badge badge-sm badge-ghost shrink-0 font-mono">
              <span class="font-semibold">{s.verb}</span>&nbsp;{s.path}
            </code>
            <p class="text-xs text-base-content/60">{s.note}</p>
          </div>
        </div>
      </section>

      <%!-- ── Source systems ────────────────────────────────────────────────── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">Integrated source systems</h2>
        <p class="text-sm text-base-content/60">
          Each system is reached through one adapter that maps its data into
          Tragar's domain shape — so the rest of the app is source-agnostic.
        </p>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div :for={sys <- @systems} class="card border border-base-300 bg-base-100">
            <div class="card-body p-4 gap-2">
              <div class="flex items-center justify-between gap-2">
                <span class="font-semibold">{sys.name}</span>
                <span class={"badge badge-sm " <> if(sys.connected, do: "badge-success", else: "badge-ghost")}>
                  {if sys.connected, do: "connected", else: "not provisioned"}
                </span>
              </div>
              <div class="flex flex-wrap gap-1">
                <span :for={c <- sys.capabilities} class="badge badge-xs badge-outline font-mono">
                  {c}
                </span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <%!-- ── Domain entities & fan-out ─────────────────────────────────────── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">Domain entities</h2>
        <p class="text-sm text-base-content/60">
          A broad question about an entity fans out over every source capability
          that describes it, then harmonises the slices into one record.
        </p>

        <div class="grid gap-3 lg:grid-cols-2">
          <div :for={e <- @entities} class="card border border-base-300 bg-base-100">
            <div class="card-body p-4 gap-2">
              <div class="flex items-center gap-2">
                <span class="font-semibold capitalize">{e.entity}</span>
                <span class="badge badge-xs badge-neutral font-mono">{e.param}</span>
              </div>
              <table class="table table-xs">
                <tbody>
                  <tr :for={c <- e.capabilities}>
                    <td class="font-mono">{c.intent}</td>
                    <td class="text-base-content/60">{c.source || "—"}</td>
                    <td class="text-xs text-base-content/60">{c.description}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </section>

      <%!-- ── Full capability catalogue ─────────────────────────────────────── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">Capability catalogue</h2>
        <p class="text-sm text-base-content/60">
          The complete read-tool schema handed to the model — it may only name one
          of these; Elixir still validates the required entities and executes it.
        </p>

        <table class="table table-sm">
          <thead>
            <tr>
              <th>Capability</th>
              <th>Source</th>
              <th>Requires</th>
              <th>What it answers</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @catalog}>
              <td class="font-mono whitespace-nowrap">{c.intent}</td>
              <td class="whitespace-nowrap text-base-content/70">{c.source || "—"}</td>
              <td class="whitespace-nowrap">
                <span :if={c.required == []} class="text-base-content/40">—</span>
                <span :for={r <- c.required} class="badge badge-xs badge-outline font-mono">{r}</span>
              </td>
              <td class="text-base-content/70">{c.description}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <%!-- ── Change actions ────────────────────────────────────────────────── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">Change actions</h2>
        <p class="text-sm text-base-content/60">
          The assistant never writes to a source. It recognises a change and hands
          it back — the agent performs it in the source app, then updates the ticket.
        </p>

        <div class="grid gap-3 sm:grid-cols-3">
          <div :for={c <- @changes} class="card border border-warning/40 bg-warning/5">
            <div class="card-body p-4 gap-1">
              <span class="font-semibold capitalize">{c.entity}</span>
              <p class="text-xs text-base-content/70">{c.verbs} · in {c.where}</p>
              <div :if={c.functions != []} class="flex flex-wrap gap-1 pt-1">
                <span :for={f <- c.functions} class="badge badge-xs badge-ghost font-mono">{f}</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <%!-- ── The two Freshdesk flows ───────────────────────────────────────── --%>
      <section class="grid gap-6 md:grid-cols-2">
        <div class="space-y-3">
          <h2 class="text-lg font-semibold">Ticket auto-answer</h2>
          <ol class="steps steps-vertical">
            <li class="step step-primary">
              Freshdesk posts a ticket to <code>/api/tickets/answer</code>
            </li>
            <li class="step step-primary">The safe loop interprets, validates and fetches</li>
            <li class="step step-primary">The answer is posted back as a private note</li>
            <li class="step step-primary">The agent reviews and replies to the customer</li>
          </ol>
        </div>

        <div class="space-y-3">
          <h2 class="text-lg font-semibold">Guided quote</h2>
          <p class="text-sm text-base-content/60">
            A pricing question (the <code>quick_quote</code>
            capability) enters here. One question at a time, per ticket, until
            FreightWare has what it needs to rate — a quick quote for a price, then
            the FreightWare quote on confirmation.
          </p>
          <ol class="steps steps-vertical">
            <li :for={s <- @quote_slots} class="step step-primary">
              <div class="text-left">
                <span class="font-mono font-semibold capitalize">{s.key}</span>
                <p class="text-xs text-base-content/60 max-w-md">{s.question}</p>
              </div>
            </li>
            <li class="step step-success">Confirm → create/accept the quote in FreightWare</li>
          </ol>
        </div>
      </section>

      <p class="text-xs text-base-content/40 pt-4 border-t border-base-200">
        Rendered live from the running modules — Adapters, Assist.Entities /
        Tools / Actions, and QuoteIntake.Flow. Nothing here is stored or editable.
      </p>
    </div>
    """
  end

  # ── View helpers ─────────────────────────────────────────────────────────────

  defp owner_class("Core AI"), do: "badge-info"
  defp owner_class("Elixir"), do: "badge-success"
  defp owner_class("Adapters"), do: "badge-warning"
  defp owner_class(_), do: "badge-ghost"
end
