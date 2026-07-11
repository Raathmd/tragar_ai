// Tragar AI ticket-sidebar app — the TRIGGER for the assist answer.
//
// The agent clicks "Ask Tragar AI". If the ticket has attachments, a picker
// appears so they choose which to ingest (some are irrelevant). Then the app
// fires the existing answer webhook (POST /api/tickets/answer) with the chosen
// attachment ids. The Elixir app extracts them server-side, folds the text into
// the answer, and posts the result as a private note — exactly like the current
// flow, plus the attachments. This app REPLACES the automation trigger.

let client;
let ticketId;

document.addEventListener("DOMContentLoaded", init);

async function init() {
  try {
    client = await app.initialized();
    const { ticket } = await client.data.get("ticket");
    ticketId = String(ticket.id);
    renderIdle();
  } catch {
    setRoot("<p class='err'>Couldn't load the ticket. Reload and try again.</p>");
  }
}

// ── Views ────────────────────────────────────────────────────────────────────

function renderIdle() {
  setRoot(`
    <p class="lead">Ask Tragar AI to answer this ticket. It posts a private note for you to review.</p>
    <button id="ask" class="primary">Ask Tragar AI</button>
    <div id="status" class="status"></div>
  `);
  byId("ask").addEventListener("click", onAsk);
}

function renderPicker(attachments) {
  // The list endpoint already returns only readable types — every row is
  // extractable, checked by default; the agent unticks anything irrelevant.
  const rows = attachments
    .map(
      (a) => `
        <li>
          <label>
            <input type="checkbox" class="att" value="${a.id}" checked />
            <span class="name" title="${esc(a.name)}">${esc(a.name)}</span>
          </label>
        </li>`
    )
    .join("");

  setRoot(`
    <p class="lead">Which attachments should Tragar AI read?</p>
    <ul class="atts">${rows}</ul>
    <div class="actions">
      <button id="go" class="primary">Answer</button>
      <button id="skip" class="ghost">Answer without them</button>
    </div>
    <div id="status" class="status"></div>
  `);

  byId("go").addEventListener("click", () => fireAnswer(checkedIds()));
  byId("skip").addEventListener("click", () => fireAnswer([]));
}

// ── Actions ──────────────────────────────────────────────────────────────────

async function onAsk() {
  setStatus("Checking attachments…");
  try {
    const res = await client.request.invokeTemplate("listAttachments", {
      context: { ticket_id: ticketId }
    });
    const { attachments } = JSON.parse(res.response);

    if (attachments && attachments.length) {
      renderPicker(attachments);
    } else {
      fireAnswer([]);
    }
  } catch {
    // No attachments endpoint reachable → still answer, just without attachments.
    fireAnswer([]);
  }
}

async function fireAnswer(attachmentIds) {
  setStatus("Tragar AI is working — the private note will appear on the ticket shortly.");
  try {
    await client.request.invokeTemplate("answer", {
      body: JSON.stringify({ ticket_id: ticketId, attachment_ids: attachmentIds })
    });
    setStatus("Sent. Check the ticket's private notes in a moment.");
  } catch {
    setStatus("Couldn't reach Tragar AI. Please try again.");
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function checkedIds() {
  return Array.from(document.querySelectorAll("input.att:checked")).map((el) =>
    Number(el.value)
  );
}

function setRoot(html) {
  byId("root").innerHTML = html;
}

function setStatus(text) {
  const el = byId("status");
  if (el) el.textContent = text;
}

function byId(id) {
  return document.getElementById(id);
}

function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
  });
}
