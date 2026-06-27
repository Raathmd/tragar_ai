# Tragar Core AI sidecar

> **Not the qwen path.** On the mini the app talks **directly to Ollama/qwen3:30b**
> (`CORE_AI_MODE=ollama`), and falls back to the in-process stub if qwen is down.
> This sidecar is an **optional** alternative provider (`CORE_AI_MODE=http`) — use
> it only if you want a separate model service in front of the app.

A model service that the Phoenix app calls in `CORE_AI_MODE=http`. Implements the
contract (see [`../docs/ml-sidecar.md`](../docs/ml-sidecar.md)):

| Endpoint | Body | Response |
|---|---|---|
| `POST /interpret` | `{question, context, tools}` | `{intent, entities}` |
| `POST /phrase` | `{intent, facts, context}` | `{answer}` |
| `GET /health` | — | `200 {"ok": true}` |

This starter is **deterministic rule-based** so the wiring works immediately —
replace the bodies of `interpret()` / `phrase()` in `app.py` with your model.
Keep the request/response shapes; that's the integration contract.

## Run locally
```bash
cd coreai
pip install -r requirements.txt
uvicorn app:app --port 8080 --reload
curl localhost:8080/health
curl -s localhost:8080/interpret -H 'content-type: application/json' \
  -d '{"question":"where is waybill 0006794936FC?","context":{},"tools":[]}'
```

Point the app at it (in the mini's `.env`):
```dotenv
CORE_AI_MODE=http
CORE_AI_URL=http://coreai:8080   # service name on the compose network
```

## Adding your model
- Put weights in the `models:` volume (mounted at `/models`, `MODEL_DIR`), not the image.
- Load the model at startup; call it inside `interpret()` / `phrase()`.
- For an LLM, run Ollama/vLLM as the base and let this service be the thin
  `/interpret` `/phrase` adapter in front of it.
- GPU: see `docs/ml-sidecar.md`.

## Deploy
Built + shipped by `.github/workflows/coreai.yml` (triggers on `coreai/**`):
test/build → push `ghcr.io/raathmd/tragar-coreai` → the mini's self-hosted runner
`docker compose --profile ai up -d --wait coreai`. Independent of the app's pipeline.
