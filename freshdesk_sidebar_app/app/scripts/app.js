// Tragar AI ticket-sidebar app.
//
// Reads the current ticket, then runs an interactive assist chat: each message
// is POSTed (via the secure Request Method template `tragarChat`) to Tragar AI's
// synchronous endpoint `POST /api/tickets/chat`, scoped to the ticket requester's
// entitled accounts server-side. The transcript is held locally and replayed each
// turn so follow-ups resolve in context (the endpoint is stateless).

let client;
let ticketId;
const history = []; // [{ role: "user" | "assistant", text }]

document.addEventListener("DOMContentLoaded", init);

async function init() {
  try {
    client = await app.initialized();
    const { ticket } = await client.data.get("ticket");
    ticketId = String(ticket.id);
    render("assistant", "Hi — ask me anything about this ticket (a waybill, a shipper reference, a quote…).");
  } catch (err) {
    render("error", "Couldn't load the ticket context. Reload the ticket and try again.");
  }

  document.getElementById("chat-form").addEventListener("submit", onSubmit);
}

async function onSubmit(event) {
  event.preventDefault();
  const input = document.getElementById("msg");
  const message = input.value.trim();
  if (!message) return;
  input.value = "";
  await send(message);
}

async function send(message) {
  render("user", message);
  history.push({ role: "user", text: message });
  clearOptions();
  setBusy(true);

  try {
    const res = await client.request.invokeTemplate("tragarChat", {
      body: JSON.stringify({ ticket_id: ticketId, message, history })
    });

    const data = JSON.parse(res.response);
    render("assistant", data.reply || "(no answer)");
    if (data.reply) history.push({ role: "assistant", text: data.reply });
    renderOptions(data.options || []);
  } catch (err) {
    // invokeTemplate rejects with { status, response } on non-2xx.
    render("error", "Tragar AI couldn't answer that just now. Please try again.");
  } finally {
    setBusy(false);
  }
}

function render(role, text) {
  const log = document.getElementById("log");
  const bubble = document.createElement("div");
  bubble.className = "bubble " + role;
  bubble.textContent = text;
  log.appendChild(bubble);
  log.scrollTop = log.scrollHeight;
}

// Clickable prompts the endpoint may return (e.g. offering a specific account).
// Clicking one simply sends its value as the next message.
function renderOptions(options) {
  const box = document.getElementById("opts");
  box.innerHTML = "";
  options.forEach((opt) => {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "chip";
    chip.textContent = opt.label;
    chip.addEventListener("click", () => send(opt.value));
    box.appendChild(chip);
  });
}

function clearOptions() {
  document.getElementById("opts").innerHTML = "";
}

function setBusy(busy) {
  document.getElementById("send").disabled = busy;
  document.getElementById("msg").disabled = busy;
}
