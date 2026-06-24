//! Tragar Pastel → mini ingestion: the SHARED PROTOCOL.
//!
//! One source of truth, compiled into BOTH the Windows SENDER and the mini
//! RECEIVER so the two cannot drift. Defines:
//!   - the on-disk / on-wire encryption envelope (XChaCha20-Poly1305)
//!   - the plaintext batch header + NDJSON row layout
//!   - the per-table monotonic sequence rules (gap / duplicate / in-order)
//!   - the HTTP contract (paths, headers, status-code -> sender action)
//!
//! Zig version: pinned to 0.14.1 (see ../README.md). std-only, no external deps,
//! so it cross-compiles unchanged for `x86-windows` (sender) and the mini target
//! (receiver).

const std = @import("std");

const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;

// ── File / envelope format ──────────────────────────────────────────────────
// Layout (versioned so both sides stay in lockstep):
//   magic(4) | version(1) | nonce(24) | ciphertext | tag(16)
// magic+version are authenticated as AAD, so a downgrade/format swap is rejected
// by the Poly1305 tag the same as any other tamper.

pub const MAGIC = [4]u8{ 'T', 'G', 'P', 'B' }; // Tragar Pastel Batch
pub const VERSION: u8 = 1;

pub const key_len = XChaCha20Poly1305.key_length; // 32
pub const nonce_len = XChaCha20Poly1305.nonce_length; // 24
pub const tag_len = XChaCha20Poly1305.tag_length; // 16
const header_len = MAGIC.len + 1; // magic|version, used as AAD
pub const overhead = header_len + nonce_len + tag_len; // 45

pub const OpenError = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    AuthenticationFailed,
};

/// Decode a 256-bit symmetric key from the base64 in BATCH_ENCRYPTION_KEY.
pub fn keyFromBase64(b64: []const u8) ![key_len]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(b64);
    if (n != key_len) return error.InvalidKeyLength;
    var key: [key_len]u8 = undefined;
    try decoder.decode(&key, b64);
    return key;
}

/// Encrypt `plaintext` into a fresh envelope. Caller owns the returned buffer.
/// A random per-file nonce is drawn; the plaintext is never written in clear.
pub fn seal(allocator: std.mem.Allocator, key: [key_len]u8, plaintext: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, overhead + plaintext.len);
    errdefer allocator.free(out);

    @memcpy(out[0..MAGIC.len], &MAGIC);
    out[MAGIC.len] = VERSION;

    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    @memcpy(out[header_len .. header_len + nonce_len], &nonce);

    const ct = out[header_len + nonce_len .. header_len + nonce_len + plaintext.len];
    var tag: [tag_len]u8 = undefined;
    const aad = out[0..header_len];
    XChaCha20Poly1305.encrypt(ct, &tag, plaintext, aad, nonce, key);
    @memcpy(out[header_len + nonce_len + plaintext.len ..], &tag);
    return out;
}

/// Verify + decrypt an envelope. Returns the plaintext (caller owns it) or an
/// OpenError. AuthenticationFailed means the file was altered (or wrong key) and
/// MUST be rejected by the receiver (§0.2 / 422).
pub fn open(allocator: std.mem.Allocator, key: [key_len]u8, file: []const u8) OpenError![]u8 {
    if (file.len < overhead) return error.Truncated;
    if (!std.mem.eql(u8, file[0..MAGIC.len], &MAGIC)) return error.BadMagic;
    if (file[MAGIC.len] != VERSION) return error.UnsupportedVersion;

    var nonce: [nonce_len]u8 = undefined;
    @memcpy(&nonce, file[header_len .. header_len + nonce_len]);

    const ct = file[header_len + nonce_len .. file.len - tag_len];
    var tag: [tag_len]u8 = undefined;
    @memcpy(&tag, file[file.len - tag_len ..]);

    const aad = file[0..header_len];
    const pt = allocator.alloc(u8, ct.len) catch return error.Truncated;
    errdefer allocator.free(pt);
    XChaCha20Poly1305.decrypt(pt, ct, tag, aad, nonce, key) catch return error.AuthenticationFailed;
    return pt;
}

// ── Plaintext: batch header + NDJSON rows ───────────────────────────────────
// The plaintext inside the envelope is:
//   line 0  : the batch header, one JSON object (field order below)
//   line 1+ : the rows, NDJSON (one JSON object per line)
// Header field order (documented contract — do not reorder):
//   source, table, run_id, seq, row_count, created_at, class

pub const Class = enum { transaction, master };

pub const BatchHeader = struct {
    source: []const u8,
    table: []const u8,
    run_id: []const u8,
    seq: u64,
    row_count: u64,
    created_at: []const u8, // RFC3339, e.g. "2026-06-24T02:00:00Z"
    class: Class,
};

/// Serialize the header to its single JSON line (no trailing newline). Inputs
/// are identifiers / RFC3339 / run-ids — assumed free of control chars and
/// quotes; the caller (batch producer) guarantees that.
pub fn headerToJson(allocator: std.mem.Allocator, h: BatchHeader) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"source\":\"{s}\",\"table\":\"{s}\",\"run_id\":\"{s}\",\"seq\":{d},\"row_count\":{d},\"created_at\":\"{s}\",\"class\":\"{s}\"}}",
        .{ h.source, h.table, h.run_id, h.seq, h.row_count, h.created_at, @tagName(h.class) },
    );
}

// ── Integrity hashing ───────────────────────────────────────────────────────
// plaintext_sha256 is computed over the full plaintext (header line + "\n" +
// NDJSON rows), i.e. exactly the bytes passed to seal(). It is sent as a POST
// metadata field and re-verified by the receiver after decrypt.

pub fn sha256(data: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &out, .{});
    return out;
}

pub fn sha256Hex(data: []const u8) [Sha256.digest_length * 2]u8 {
    return std.fmt.bytesToHex(sha256(data), .lower);
}

// ── Sequence rules (§0.1) ───────────────────────────────────────────────────
// Monotonic per-(source,table) sequence starting at 1. The receiver tracks
// last_processed_seq (0 before any batch) and expects last+1.

pub const SeqOutcome = enum {
    in_order, // seq == last + 1  -> process
    duplicate, // seq <= last      -> idempotent no-op (already have it)
    gap, // seq >  last + 1  -> an earlier batch is missing, reject
};

pub fn classifySeq(last_processed: u64, incoming: u64) SeqOutcome {
    if (incoming == last_processed + 1) return .in_order;
    if (incoming <= last_processed) return .duplicate;
    return .gap;
}

// ── batch_id ────────────────────────────────────────────────────────────────
// batch_id = "<source>:<table>:<seq>"

pub fn buildBatchId(allocator: std.mem.Allocator, source: []const u8, table: []const u8, seq: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ source, table, seq });
}

pub const ParsedBatchId = struct { source: []const u8, table: []const u8, seq: u64 };

pub fn parseBatchId(s: []const u8) !ParsedBatchId {
    const first = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadBatchId;
    const last = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadBatchId;
    if (first == last) return error.BadBatchId; // need two separators
    const source = s[0..first];
    const table = s[first + 1 .. last];
    const seq = std.fmt.parseInt(u64, s[last + 1 ..], 10) catch return error.BadBatchId;
    if (source.len == 0 or table.len == 0) return error.BadBatchId;
    return .{ .source = source, .table = table, .seq = seq };
}

// ── HTTP contract (§0.4) ────────────────────────────────────────────────────

pub const http = struct {
    pub const auth_header = "authorization";
    pub const bearer_prefix = "Bearer ";

    pub const healthz = "/healthz";
    pub const ingest_batch = "/ingest/batch";
    pub const ingest_status = "/ingest/status";

    // POST /ingest/batch metadata field names (sent as query params or a small
    // JSON/multipart prefix; the encrypted file is the body).
    pub const field_batch_id = "batch_id";
    pub const field_source = "source";
    pub const field_table = "table";
    pub const field_seq = "seq";
    pub const field_plaintext_sha256 = "plaintext_sha256";
};

/// Per-batch processing state in the receiver's ingestion ledger (§1.6 / §2).
pub const ProcessingState = enum { received, processing, processed, failed };

/// The sender keys ALL retry decisions off the POST /ingest/batch status code.
pub const SenderAction = enum {
    advance, // 200 / 409: received (or dup) -> advance last_confirmed_seq
    retry_same, // 422: do NOT advance; re-check sequence; re-send same batch
    retry_backoff, // 5xx / network: leave unconfirmed; retry with backoff
    halt, // 400 / 401: config/auth problem -> stop and alert, don't loop
};

pub fn actionForStatus(status: u16) SenderAction {
    return switch (status) {
        200, 409 => .advance,
        422 => .retry_same,
        400, 401 => .halt,
        else => if (status >= 500) .retry_backoff else .halt,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const test_key: [key_len]u8 = [_]u8{0x42} ** key_len;

test "envelope round-trip" {
    const a = testing.allocator;
    const pt = "{\"source\":\"pastel\"}\n{\"RecordNumber\":1}\n{\"RecordNumber\":2}";
    const sealed = try seal(a, test_key, pt);
    defer a.free(sealed);

    try testing.expect(sealed.len == overhead + pt.len);
    try testing.expectEqualSlices(u8, &MAGIC, sealed[0..MAGIC.len]);
    try testing.expectEqual(VERSION, sealed[MAGIC.len]);

    const opened = try open(a, test_key, sealed);
    defer a.free(opened);
    try testing.expectEqualSlices(u8, pt, opened);
}

test "tamper: flipped ciphertext byte is rejected" {
    const a = testing.allocator;
    const sealed = try seal(a, test_key, "hello world payload");
    defer a.free(sealed);
    sealed[overhead] ^= 0x01; // flip first ciphertext byte
    try testing.expectError(error.AuthenticationFailed, open(a, test_key, sealed));
}

test "tamper: flipped version (AAD) is rejected" {
    const a = testing.allocator;
    const sealed = try seal(a, test_key, "payload");
    defer a.free(sealed);
    sealed[MAGIC.len] = 2; // bump version -> UnsupportedVersion before tag check
    try testing.expectError(error.UnsupportedVersion, open(a, test_key, sealed));
}

test "tamper: flipped tag byte is rejected" {
    const a = testing.allocator;
    const sealed = try seal(a, test_key, "payload bytes here");
    defer a.free(sealed);
    sealed[sealed.len - 1] ^= 0xFF;
    try testing.expectError(error.AuthenticationFailed, open(a, test_key, sealed));
}

test "wrong key is rejected" {
    const a = testing.allocator;
    const sealed = try seal(a, test_key, "secret");
    defer a.free(sealed);
    const other: [key_len]u8 = [_]u8{0x99} ** key_len;
    try testing.expectError(error.AuthenticationFailed, open(a, other, sealed));
}

test "truncated / bad magic rejected" {
    const a = testing.allocator;
    try testing.expectError(error.Truncated, open(a, test_key, "short"));
    var buf: [overhead + 4]u8 = [_]u8{0} ** (overhead + 4);
    buf[0] = 'X';
    try testing.expectError(error.BadMagic, open(a, test_key, &buf));
}

test "plaintext_sha256 matches std" {
    const data = "the quick brown fox";
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &expected, .{});
    try testing.expectEqualSlices(u8, &expected, &sha256(data));
    const hex = sha256Hex(data);
    try testing.expectEqual(@as(usize, 64), hex.len);
}

test "sequence classification: in-order / duplicate / gap" {
    try testing.expectEqual(SeqOutcome.in_order, classifySeq(0, 1));
    try testing.expectEqual(SeqOutcome.in_order, classifySeq(7, 8));
    try testing.expectEqual(SeqOutcome.duplicate, classifySeq(7, 7));
    try testing.expectEqual(SeqOutcome.duplicate, classifySeq(7, 3));
    try testing.expectEqual(SeqOutcome.gap, classifySeq(7, 9));
    try testing.expectEqual(SeqOutcome.gap, classifySeq(0, 2));
}

test "status code -> sender action (§0.4)" {
    try testing.expectEqual(SenderAction.advance, actionForStatus(200));
    try testing.expectEqual(SenderAction.advance, actionForStatus(409));
    try testing.expectEqual(SenderAction.retry_same, actionForStatus(422));
    try testing.expectEqual(SenderAction.halt, actionForStatus(400));
    try testing.expectEqual(SenderAction.halt, actionForStatus(401));
    try testing.expectEqual(SenderAction.retry_backoff, actionForStatus(500));
    try testing.expectEqual(SenderAction.retry_backoff, actionForStatus(503));
}

test "batch_id build + parse round-trip" {
    const a = testing.allocator;
    const id = try buildBatchId(a, "pastel", "HistoryHeader", 42);
    defer a.free(id);
    try testing.expectEqualStrings("pastel:HistoryHeader:42", id);
    const p = try parseBatchId(id);
    try testing.expectEqualStrings("pastel", p.source);
    try testing.expectEqualStrings("HistoryHeader", p.table);
    try testing.expectEqual(@as(u64, 42), p.seq);
    try testing.expectError(error.BadBatchId, parseBatchId("nocolons"));
    try testing.expectError(error.BadBatchId, parseBatchId("only:one"));
}

test "header JSON field order is the documented contract" {
    const a = testing.allocator;
    const h = BatchHeader{
        .source = "pastel",
        .table = "CustomerMaster",
        .run_id = "run-2026-06-24T0200Z",
        .seq = 3,
        .row_count = 128,
        .created_at = "2026-06-24T02:00:00Z",
        .class = .master,
    };
    const js = try headerToJson(a, h);
    defer a.free(js);
    try testing.expectEqualStrings(
        "{\"source\":\"pastel\",\"table\":\"CustomerMaster\",\"run_id\":\"run-2026-06-24T0200Z\",\"seq\":3,\"row_count\":128,\"created_at\":\"2026-06-24T02:00:00Z\",\"class\":\"master\"}",
        js,
    );
}
