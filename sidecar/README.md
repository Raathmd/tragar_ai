# Tragar Core AI — Swift sidecar

The on-device "Core AI" for the Tragar app, using Apple's **Foundation Models**
framework (the built-in Apple Intelligence model — no model download). It serves
two endpoints over local HTTP that `TragarAi.CoreAI` (`:http` mode) calls:

- `POST /interpret` — `{"question": "...", "context": {...}}` →
  `{"intent": "load_status", "entities": {"waybill": "4821"}}`
- `POST /phrase` — `{"intent": "...", "facts": {...}, "context": {...}}` →
  `{"answer": "..."}`
- `GET /` — health: `{"status": "ok", "model": "available"}`

All on-device; nothing leaves the machine.

## Requirements

- A Mac with **Apple Intelligence** (M1 or later) running **macOS 26 (Tahoe)**.
- **Apple Intelligence enabled**: System Settings → Apple Intelligence & Siri →
  turn on (this downloads Apple's on-device model assets once).
- **Xcode 26** / Swift 6 toolchain (`xcode-select --install` or full Xcode).

## Build & run

```bash
cd sidecar
swift build -c release
PORT=11434 .build/release/TragarCoreAI
```

You should see: `listening on http://127.0.0.1:11434 — model available`. If it
says `unavailable: ...`, enable Apple Intelligence (above) and retry.

Smoke test:

```bash
curl -s localhost:11434/ | jq
curl -s localhost:11434/interpret -d '{"question":"Where is load 4821?"}' | jq
```

## Point the Elixir app at it

```bash
export CORE_AI_MODE=http
export CORE_AI_URL=http://127.0.0.1:11434
mix phx.server
```

The deterministic stub (`CORE_AI_MODE=stub`, the default) remains the fallback if
the sidecar isn't running.

## Run it under launchd (resilient, auto-restart)

For the on-prem mini, run the sidecar as a Launch Agent so it starts on login and
restarts on crash (pairs with the UPS/auto-restart resilience in the plan). A
`launchd` plist pointing at `.build/release/TragarCoreAI` with `KeepAlive=true`
is enough.

## Notes

- A fresh `LanguageModelSession` is created per request (stateless).
- `/interpret` uses **guided generation** (`@Generable Interpretation`) so the
  model returns a constrained, parseable structure.
- The Foundation Models API is young; if a symbol differs in your installed SDK
  (e.g. `respond(to:generating:)`), adjust `CoreAI.swift` accordingly — the HTTP
  contract above is what the Elixir side depends on and should stay stable.
