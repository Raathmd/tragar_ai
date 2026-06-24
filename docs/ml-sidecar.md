# ML model sidecars on the mini

The app is already built as a **sidecar client**: `TragarAi.CoreAI` in `:http`
mode POSTs to a model service over local HTTP. So an ML workload is just another
container on the Compose network that the app talks to — no app changes needed,
just a URL.

```
┌──────────── docker network ────────────┐
│  app (Phoenix)  ──HTTP──►  coreai       │   CORE_AI_URL=http://coreai:8080
│  app           ──HTTP──►  extractor     │   (additional model sidecars)
│  db (Postgres)                          │
└─────────────────────────────────────────┘
```

## The contract a Core AI sidecar must implement
Three endpoints (JSON):

| Method | Body | Response |
|---|---|---|
| `POST /interpret` | `{question, context, tools}` — `tools` is the function schema (`Assist.Tools.schema`) | `{intent, entities}` (or a `tool_call`) |
| `POST /phrase` | `{intent, facts, context}` | `{answer}` |
| `GET /health` | — | `200` |

`context` carries `entities`/`agent`; `tools` lets the model pick a valid call.
Elixir still **validates and executes** — the model only interprets/phrases.

## Two ways to build the sidecar
1. **Your own model service** (recommended for custom models): a small
   FastAPI/BentoML app that loads your model from `/models` and implements the
   three endpoints above. Package as `ghcr.io/raathmd/tragar-coreai`.
2. **Wrap an LLM runtime**: run **Ollama / vLLM / llama.cpp / TGI** for the base
   model and put a thin `/interpret` `/phrase` adapter in front (those runtimes
   speak their own API, not ours).

Minimal sidecar skeleton (FastAPI):
```python
from fastapi import FastAPI
app = FastAPI()

@app.get("/health")
def health(): return {"ok": True}

@app.post("/interpret")
def interpret(body: dict):
    # body: {question, context, tools}; run your model → choose intent + entities
    return {"intent": "...", "entities": {...}}

@app.post("/phrase")
def phrase(body: dict):
    # body: {intent, facts, context}; compose the answer
    return {"answer": "..."}
```

## Adding more ML workloads
Each model = one more service on the network (e.g. an `extractor` for parsing
quote requests, a `classifier` for ticket routing). Add a service to
`docker-compose.yml`, give it a health check, and call it from a small Elixir
client module (mirror `TragarAi.CoreAI` / `TragarAi.Vantage.Client`).

## GPU
If the mini has an NVIDIA GPU: install the NVIDIA Container Toolkit, then
uncomment the `deploy.resources.reservations.devices` block on the `coreai`
service. CPU-only models need nothing.

## Model artifacts
Keep weights **out of the image** — they're large and change on a different
cadence than code. The `models:` volume holds them; the sidecar pulls/loads at
start (or you `docker cp` / mount them). The app image stays small and rebuilds fast.

## CI/CD — same pull-based flow, independent versioning
The sidecar is its **own image** with its **own pipeline** (its repo's CI builds
+ pushes `tragar-coreai` to GHCR). The mini's self-hosted runner deploys it the
same way as the app:
```bash
COREAI_IMAGE=ghcr.io/raathmd/tragar-coreai:<sha> docker compose --profile ai pull
docker compose --profile ai up -d coreai
```
So you can ship a new **model** without redeploying the app, and vice versa.

## Switching the app to use it
Once `coreai` is healthy, in the mini's `.env`:
```dotenv
CORE_AI_MODE=http
CORE_AI_URL=http://coreai:8080
CORE_AI_MODEL=<name, for display>
```
then `docker compose --profile ai up -d`. Until then the app runs in `:stub`
mode (deterministic, no model) — the contract is identical, so nothing
downstream changes when the model arrives.
