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

## Zig version — pinned

**Zig `0.14.1`.** Reasons: stable `std.crypto.aead.chacha_poly.XChaCha20Poly1305`
and `std.crypto.hash.sha2.Sha256`; the `std.Build` module/test API used here is
stable on 0.14.x; reliable `x86-windows` cross-compilation for the 32-bit
sender. The pin is recorded in `shared/build.zig.zon` (`minimum_zig_version`).
*If you want a different pin, say so before we build the two programs — the
`std.http` server/client and `build.zig` APIs differ across 0.13/0.14/0.15 and
the choice affects both binaries.*

Run the shared tests:

```bash
cd zig/shared && zig build test
```

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

## Open questions — awaiting confirmation

1. **Zig pin** — OK to lock `0.14.1`? (affects `std.http` + `build.zig` in both
   programs.)
2. **Live Pastel table list** — `config.toml.example` is a *model*, not verified.
   We need an ODBC-catalog dump from the live install (`SQLTables` / `SQLColumns`)
   to confirm: real transaction/master table names, the monotonic
   record-number column per transaction table, and the natural key columns. This
   is the blocker for building the SENDER's ODBC reader.
3. **Receiver ledger store** — Postgres (recommended: same DB, same txn as the
   upsert so state+data move atomically) vs a separate SQLite file?
4. **Postgres access from the receiver** — link `libpq` (simpler, robust) vs a
   pure-Zig v3 wire client (no C dep)? Loopback, no TLS needed either way.

Once 1–4 are settled we build out `sender/` and `receiver/`, the DDL (staging /
read model / ledger), and the integration tests against a real DSN + local PG.
