"""
Tragar Core AI sidecar — implements the contract TragarAi.CoreAI (:http mode)
calls: POST /interpret, POST /phrase, GET /health.

This starter is a deterministic, rule-based placeholder so the wiring works out
of the box. Replace the body of `interpret()` and `phrase()` with your model —
the request/response shapes are the integration contract; keep them.
"""

import re

from fastapi import FastAPI

app = FastAPI(title="Tragar Core AI sidecar", version="0.1.0")

# Entity patterns (mirror the Elixir stub closely enough to be useful).
RE_QUOTE = re.compile(r"\bquote\s*#?\s*(\d{3,})\b", re.I)
RE_ACCOUNT = re.compile(r"\b(ACC\d{2,}|[A-Z]{2,}\d{2,})\b")
RE_WAYBILL = re.compile(r"\b(\d{4,}[A-Z]{0,4})\b", re.I)


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/interpret")
async def interpret(body: dict):
    """body: {question, context, tools} -> {intent, entities}.

    `tools` is the function schema (names = allowed intents + required entities).
    The model should pick a valid tool and fill its entities. Elixir then
    validates and executes — never trust this to fetch anything itself.
    """
    question = body.get("question") or ""
    q = question.lower()
    entities = _entities(question)

    # TODO: replace this keyword routing with your model's tool/intent choice.
    if "stock" in q or "on hand" in q:
        intent = "stock"
    elif "service" in q and "type" in q:
        intent = "service_types"
    elif "invoice" in q or "balance" in q or "owe" in q:
        intent = "invoice"
    elif "quote" in q:
        intent = "quote_lookup"
    elif "proof of delivery" in q or "pod" in q or "signed" in q:
        intent = "pod"
    elif "route" in q or "distance" in q:
        intent = "route"
    elif "eta" in q or "when will" in q or "arrive" in q:
        intent = "eta"
    elif "track" in q or "history" in q:
        intent = "track"
    elif "customer" in q or "who is" in q or "account" in q:
        intent = "customer_lookup"
    else:
        intent = "load_status"  # "where is …"

    return {"intent": intent, "entities": entities}


@app.post("/phrase")
async def phrase(body: dict):
    """body: {intent, facts, context} -> {answer}."""
    intent = body.get("intent")
    facts = body.get("facts") or {}

    # TODO: replace with your model. Until then, template from the facts.
    wb = facts.get("waybill_number")
    status = facts.get("status_description") or facts.get("status")

    if intent in ("load_status", "eta", "track") and wb:
        last = (facts.get("last_event") or {}).get("event_description")
        answer = f"Waybill {wb}: {status or 'status unavailable'}."
        if last:
            answer += f" Last update: {last}."
    elif intent == "pod" and wb:
        answer = f"Waybill {wb} — {status or 'delivery status unavailable'}."
    elif intent == "quote_lookup" and facts.get("quote_number"):
        answer = f"Quote {facts['quote_number']}: {facts.get('status', 'status unavailable')}."
    elif intent == "invoice":
        answer = f"Account {facts.get('account_reference', '')}: balance {facts.get('balance', 'unavailable')}."
    else:
        answer = _generic(facts)

    return {"answer": answer}


def _entities(question: str) -> dict:
    e = {}
    if m := RE_QUOTE.search(question):
        e["quote"] = m.group(1)
    if m := RE_ACCOUNT.search(question):
        e["account"] = m.group(1)
    if (m := RE_WAYBILL.search(question)) and "quote" not in e:
        e["waybill"] = m.group(1)
    return e


def _generic(facts: dict) -> str:
    pairs = [f"{k.replace('_', ' ')}: {v}" for k, v in facts.items() if isinstance(v, (str, int, float))]
    return "; ".join(pairs[:6]) or "No details available."
