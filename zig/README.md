# Pastel → mini ingestion (Zig)

Two Zig programs + one shared protocol that move accounting data from the
on-premise **Pastel Partner** database (Windows, Actian Zen / Pervasive PSQL)
into the mini's **PostgreSQL** read model, over HTTP, as **sequenced, encrypted
files**. The wire/file protocol is defined ONCE and compiled into both programs
so they cannot drift.

> **Status: PROPOSAL — phase 0 only.** This commit lands the *shared protocol*,
> the *config schema*, and the env contracts. The table-dependent pieces (ODBC
> reader, delivery loop, Postgres upsert) are **not** built yet — per the spec,
> we confirm the Zig version and the live Pastel table list first. See
> **[Open questions](#open-questions--awaiting-confirmation)** below.

## Layout

```
zig/
  shared/                 # THE one source of truth, imported by both programs
    protocol.zig          #   envelope crypto, header, sequence rules, HTTP contract
    build.zig             #   `zig build test` runs the protocol test suite
    build.zig.zon
  config.toml.example     # SENDER table map (names UNCONFIRMED — see file)
  sender.env.example      # SENDER secrets (Windows)
  receiver.env.example    # RECEIVER secrets (the mini)
  sender/                 # (next phase) x86-windows, links odbc32
  receiver/               # (next phase) mini target, Postgres upsert
```

## Zig version — pinned to 0.16.0

**Zig `0.16.0`** (released 2026-04-14). Recorded in `shared/build.zig.zon`
(`minimum_zig_version`). What 0.16 changes for us:

- **`build.zig.zon`**: `.name` is now an **enum literal** and `.fingerprint` is
  **mandatory** (legacy package hash removed). The fingerprint is a `0x0`
  placeholder — the first `zig build` validates it against the name and prints
  the real value to paste in (fixed forever after).
- **Build API**: `addTest` / `addExecutable` take a `.root_module` built via
  `b.createModule(...)` (used in `shared/build.zig`).
- **I/O as an Interface**: all real I/O now flows through an `Io` instance. This
  does **not** touch `shared/protocol.zig` (pure `std.crypto` / `std.fmt` /
  `std.mem` / `std.base64`), so the protocol module is unaffected. It **does**
  reshape the next phase — see [I/O interface note](#io-interface-note-next-phase).

> ✅ Compile-verified on **Zig 0.16.0**: `zig build test` → 11/11 tests pass;
> `zig fmt --check` clean; and the protocol cross-compiles for all three real
> targets — `x86-windows` (32-bit sender), `aarch64-macos` and `x86_64-macos`
> (the mini). The `.fingerprint` in `build.zig.zon` is the real toolchain-issued
> value.

Run the shared tests:

```bash
cd zig/shared && zig build test --summary all
```

**0.16 note — randomness through `Io`:** 0.16 removed `std.crypto.random`; CSPRNG
now routes through the `Io` interface (`std.Io.random(io, &buf)`). To keep the
protocol module pure and deterministically testable, `seal()` takes the 24-byte
nonce **as a parameter** (standard for AEAD libraries); the sender draws a fresh
random nonce per file via its `Io` and passes it in.

### I/O interface note (next phase)

The sender's HTTP client and outbox writes, and the receiver's HTTPS server and
file reads, must all be written against 0.16's `Io` interface: `std.http.Client`
takes `.io = io`; `std.http` server is reworked; `std.fs` reads/writes route
through `Io` (e.g. `File.readStreaming` / `std.Io.Writer.Allocating`). Budget for
this when we build `sender/` and `receiver/`.

## The protocol (phase 0 — implemented in `shared/protocol.zig`)

### Encryption envelope (authenticated, tamper-evident)
- Cipher **XChaCha20-Poly1305** (`std.crypto.aead`), per-file random 24-byte nonce.
- File layout (versioned): `magic(4) | version(1) | nonce(24) | ciphertext | tag(16)`.
  - `magic = "TGPB"`, `version = 1`.
  - `magic|version` is authenticated as **AAD**, so a format/downgrade swap is
    rejected by the tag like any other tamper.
- Shared 256-bit key, base64 in `BATCH_ENCRYPTION_KEY`, identical on both sides.
- `seal()` / `open()` round-trip; `open()` returns `AuthenticationFailed` on any
  alteration or wrong key. Plaintext is never written in clear.

### Plaintext (inside the envelope)
- Line 0: the batch **header**, one JSON object. **Field order (contract — do
  not reorder):** `source, table, run_id, seq, row_count, created_at, class`.
- Line 1+: the rows, **NDJSON** (one JSON object per line).
- `plaintext_sha256` is computed over the full plaintext (exactly the bytes
  passed to `seal`) and re-verified by the receiver after decrypt.

### Row classes
- `transaction` — append-only history/journal, keyed by monotonic record number.
- `master` — Customer / Supplier / LedgerMaster / Inventory, mutate in place,
  per-row hash so unchanged rows no-op.

### Sequence rules
Monotonic per-`(source, table)` sequence from 1. Receiver expects `last + 1`:
`classifySeq(last, incoming)` → `in_order` (process) / `duplicate` (idempotent
no-op) / `gap` (reject, don't process out of order).

### HTTP contract
`Authorization: Bearer <BATCH_TOKEN>` on every request, HTTPS to the mini.
- `GET /healthz` — connectivity pre-check.
- `POST /ingest/batch` — metadata (`batch_id, source, table, seq,
  plaintext_sha256`) + encrypted file body.
- `GET /ingest/status?source=&table=&from_seq=&to_seq=` — per-batch state.

Status → sender action (`actionForStatus`): `200/409` → **advance**; `422` →
**retry same** (don't advance); `5xx`/network → **retry with backoff**;
`400/401` → **halt & alert**.

## Decisions (confirmed) & the remaining blocker

Confirmed:
- **Zig pin** → `0.16.0` (see above).
- **Receiver ledger** → **Postgres on the mini**, so the read-model upsert and
  the `last_processed_seq` advance commit in the **same transaction** (atomic
  state+data).
- **Postgres access** → **link `libpq`** (`@cImport` `libpq-fe.h`) — robust
  COPY/binary handling; loopback so no TLS.

**Remaining blocker — the live Pastel table list.** `config.toml.example` is a
*model*, not verified. Before building the SENDER's ODBC reader we need an
ODBC-catalog dump from the live install (`SQLTables` / `SQLColumns`) to confirm:
real transaction/master table names, the **monotonic record-number column** per
transaction table, and the **natural key columns**. Please provide that (or a
DSN we can introspect) and confirm the table list.

Once the table list is confirmed we build out `sender/` (x86-windows, links
`odbc32`) and `receiver/` (links `libpq`), the DDL (staging / read model /
ledger), and the integration tests against a real DSN + local PG.
