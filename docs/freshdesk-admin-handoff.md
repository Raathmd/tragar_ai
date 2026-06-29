# Freshdesk setup for the Tragar AI ticket assistant

**For:** the Freshdesk administrator
**Goal:** when a ticket is created, Freshdesk notifies Tragar AI; Tragar AI reads the
ticket, looks up the answer in our systems, and posts it back onto the ticket as a
**private note** for the agent to review.

You'll set up **four** things in Freshdesk and exchange **two values** with the
Tragar AI ops team. None of this affects existing tickets or email.

---

## Checklist
- [ ] 1. Create a dedicated **“Tragar AI”** agent and get its **API key**
- [ ] 2. Add a **Company** custom field for the account code, and populate it
- [ ] 3. Create the **automation** that notifies Tragar AI on ticket creation
- [ ] 4. Exchange the **two values** with ops

---

## 1. Dedicated “Tragar AI” agent (so notes are attributed to it)

1. **Admin → Agents → New agent.** Name it **Tragar AI** (a support/full-time agent).
2. Give it **access to the ticket groups** the assistant should answer (it can only
   post to tickets it can see).
3. Log in as that agent (or have its profile) → **Profile settings (top-right avatar)
   → “Your API Key.”** Copy it — this is **Value A** you hand to ops.

> The AI's notes will appear as posted by **Tragar AI** rather than a real person.
> (An agent takes a seat; if you'd rather not, you can use an existing agent's API
> key instead — the notes are just attributed to that person.)

---

## 2. Company account field (so the AI answers for the right customer)

The assistant scopes every lookup to the customer's account, read from the Company.

1. **Admin → Companies → Company fields → add a custom field** named **`Account`**
   (text). Its internal key should be **`freightware_accounts`** — tell ops if it ends up
   different.
2. **Populate** each customer **Company** with its FreightWare **account code**
   (e.g. `ITD02`). If a company spans several accounts, comma-separate them
   (`ITD01, ITD02`) and the assistant will ask which to use.
3. Make sure each customer **Contact** is **linked to their Company** (so a ticket's
   requester resolves to the right account).

---

## 3. Automation: notify Tragar AI when a ticket is created

**Admin → Workflows → Automations → “Ticket Creation” tab → New rule.**

- **Name:** `Tragar AI auto-answer`
- **When:** *Ticket is created.*
  *(Optional but recommended:* add a condition so it only runs for the right Group /
  Product / Type, so we don't auto-answer every ticket.)
- **Action → Trigger Webhook:**
  - **Request type:** `POST`
  - **URL:** `https://api.tragarai.net/api/tickets/answer`
  - **Encoding:** `JSON`
  - **Custom header:** `Authorization` = `Bearer <TOKEN from ops>` ← **Value B**
  - **Content (raw JSON):**
    ```json
    {
      "ticket_id": "{{ticket.id}}",
      "subject": "{{ticket.subject}}",
      "description": "{{ticket.description_text}}",
      "requester_email": "{{ticket.requester.email}}"
    }
    ```
    *(Use the “insert placeholder” picker so the `{{ }}` tokens are exact.)*
- **Save.**

---

## 4. Two values to exchange with ops

| | Value | Direction |
|---|---|---|
| **A** | The **Tragar AI agent's API key** (from step 1) | **You → ops** |
| **B** | The **Bearer token** for the webhook header (step 3) | **ops → you** |

That's the only handshake. (Ops handles everything on the server side — hosting,
networking, and the connection to our logistics systems.)

---

## What success looks like
Create a **test ticket** (e.g. subject *“Where is waybill 1234?”*) for a contact whose
company has an account code. Within a few seconds, a **private note** with the answer
should appear on the ticket, posted by **Tragar AI**.

## Notes
- Answers post as **private notes** by default (agents review before anything reaches
  the customer). We can switch specific flows to public replies later if you want.
- You do **not** need to set up any inbound IP rules or a second webhook for the reply —
  Tragar AI posts the note back using the agent API key (Value A).
- Nothing here changes your email, existing automations, or other tickets.
- **Custom ticket fields get pre-filled.** Any **custom ticket field** you create
  (Admin → Ticket fields) whose name matches data the AI looked up — e.g. *Waybill
  status*, *Waybill number*, *Account*, *Service type*, *Consignee* — is filled in
  automatically when a ticket comes through. For **dropdowns**, only values that
  match one of your configured choices are filled (others are left blank). The AI
  **never assigns the ticket** to an agent or group — a human still owns that.
  Tell ops the exact field names if you'd like us to confirm the mapping.

## Questions for ops
- Confirm the public URL (`https://api.tragarai.net/api/tickets/answer`) and the Bearer
  token (Value B).
- Confirm the account field key (`freightware_accounts`) matches what they expect.
