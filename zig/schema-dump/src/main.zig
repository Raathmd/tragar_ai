//! schema-dump — connect to the live Pastel (Actian Zen / Pervasive PSQL)
//! database over 32-bit ODBC and emit its catalog as JSON on stdout.
//!
//! Build (on any machine): `zig build`  → produces an x86-windows .exe.
//! Run (on the Windows 10 box): use the SAME 32-bit DSN the sender will use:
//!
//!   schema-dump.exe "DSN=PastelData" > schema.json
//!   schema-dump.exe "Driver={Pervasive ODBC Client Interface};ServerName=...;DBQ=..." Table1 Table2 > schema.json
//!
//! arg 1            : the full ODBC connection string (DSN= or Driver=...).
//! args 2..N (opt)  : table names to detail. If omitted, the built-in Pastel set
//!                    is detailed. The full table list is always emitted.
//!
//! Send schema.json back so we can lock config.toml: exact column names, the
//! natural keys for the upsert, and — from the emitted index info — whether a
//! transaction table has a monotonic column to watermark on (else we fall back
//! to a per-DocumentType watermark).

const std = @import("std");
const odbc = @import("odbc.zig");

const default_tables = [_][:0]const u8{
    "HistoryHeader",  "HistoryLines",   "OpenItem",
    "CustomerMaster", "SupplierMaster", "InventoryMaster",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [1 << 15]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: schema-dump.exe \"<odbc-connection-string>\" [Table ...]\n", .{});
        std.process.exit(2);
    }
    const conn_str = args[1];
    const detail_tables: []const [:0]const u8 = if (args.len > 2) args[2..] else &default_tables;

    // ── connect ──────────────────────────────────────────────────────────────
    var env: odbc.SQLHANDLE = null;
    if (!odbc.ok(odbc.SQLAllocHandle(odbc.SQL_HANDLE_ENV, odbc.SQL_NULL_HANDLE, &env))) return fail("alloc env");
    defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_ENV, env);
    _ = odbc.SQLSetEnvAttr(env, odbc.SQL_ATTR_ODBC_VERSION, @ptrFromInt(odbc.SQL_OV_ODBC3), 0);

    var dbc: odbc.SQLHANDLE = null;
    if (!odbc.ok(odbc.SQLAllocHandle(odbc.SQL_HANDLE_DBC, env, &dbc))) return fail("alloc dbc");
    defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_DBC, dbc);

    const rc = odbc.SQLDriverConnectA(dbc, null, conn_str.ptr, odbc.SQL_NTS, null, 0, null, odbc.SQL_DRIVER_NOPROMPT);
    if (!odbc.ok(rc)) {
        var dbuf: [600]u8 = undefined;
        std.debug.print("connect failed: {s}\n", .{odbc.diag(odbc.SQL_HANDLE_DBC, dbc, &dbuf)});
        std.process.exit(1);
    }
    defer _ = odbc.SQLDisconnect(dbc);

    // ── emit JSON ──────────────────────────────────────────────────────────────
    try w.writeAll("{\n  \"product\": \"Sage 50c Pastel Partner v19.4.7\",\n");
    try w.writeAll("  \"all_tables\": [\n");
    try dumpTableList(w, dbc);
    try w.writeAll("\n  ],\n  \"detail\": [\n");
    for (detail_tables, 0..) |t, i| {
        if (i != 0) try w.writeAll(",\n");
        try dumpTableDetail(arena, w, dbc, t);
    }
    try w.writeAll("\n  ]\n}\n");
    try fw.flush();
}

fn fail(comptime what: []const u8) noreturn {
    std.debug.print("schema-dump: {s} failed\n", .{what});
    std.process.exit(1);
}

fn newStmt(dbc: odbc.SQLHANDLE) ?odbc.SQLHANDLE {
    var stmt: odbc.SQLHANDLE = null;
    if (!odbc.ok(odbc.SQLAllocHandle(odbc.SQL_HANDLE_STMT, dbc, &stmt))) return null;
    return stmt;
}

fn dumpTableList(w: *std.Io.Writer, dbc: odbc.SQLHANDLE) !void {
    const stmt = newStmt(dbc) orelse return;
    defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
    // TABLE_TYPE filter "TABLE" excludes the X$ system/catalog tables.
    const ttype = "TABLE";
    if (!odbc.ok(odbc.SQLTablesA(stmt, null, 0, null, 0, null, 0, ttype, odbc.SQL_NTS))) return;

    var name_buf: [256]u8 = undefined;
    var type_buf: [64]u8 = undefined;
    var first = true;
    while (odbc.SQLFetch(stmt) == odbc.SQL_SUCCESS) {
        const name = odbc.getText(stmt, 3, &name_buf) orelse continue; // TABLE_NAME
        const ttyp = odbc.getText(stmt, 4, &type_buf) orelse "";
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("    {\"name\": ");
        try writeJsonString(w, name);
        try w.writeAll(", \"type\": ");
        try writeJsonString(w, ttyp);
        try w.writeAll("}");
    }
}

fn dumpTableDetail(arena: std.mem.Allocator, w: *std.Io.Writer, dbc: odbc.SQLHANDLE, table: []const u8) !void {
    const tz = try arena.dupeZ(u8, table); // null-terminated for SQL_NTS calls

    try w.writeAll("    {\n      \"table\": ");
    try writeJsonString(w, table);

    // columns
    try w.writeAll(",\n      \"columns\": [\n");
    {
        const stmt = newStmt(dbc) orelse return;
        defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
        if (odbc.ok(odbc.SQLColumnsA(stmt, null, 0, null, 0, tz.ptr, odbc.SQL_NTS, null, 0))) {
            var nb: [256]u8 = undefined;
            var tb: [128]u8 = undefined;
            var sb: [64]u8 = undefined;
            var ob: [32]u8 = undefined;
            var nlb: [16]u8 = undefined;
            var first = true;
            while (odbc.SQLFetch(stmt) == odbc.SQL_SUCCESS) {
                const cname = odbc.getText(stmt, 4, &nb) orelse continue; // COLUMN_NAME
                const ctype = odbc.getText(stmt, 6, &tb) orelse ""; // TYPE_NAME
                const csize = odbc.getText(stmt, 7, &sb) orelse ""; // COLUMN_SIZE
                const cnull = odbc.getText(stmt, 11, &nlb) orelse ""; // NULLABLE
                const cord = odbc.getText(stmt, 17, &ob) orelse ""; // ORDINAL_POSITION
                if (!first) try w.writeAll(",\n");
                first = false;
                try w.writeAll("        {\"name\": ");
                try writeJsonString(w, cname);
                try w.print(", \"type\": ", .{});
                try writeJsonString(w, ctype);
                try w.print(", \"size\": {s}, \"nullable\": {s}, \"ordinal\": {s}", .{ numOrNull(csize), numOrNull(cnull), numOrNull(cord) });
                try w.writeAll("}");
            }
        }
    }
    try w.writeAll("\n      ],\n      \"primary_key\": [");

    // primary key
    {
        const stmt = newStmt(dbc) orelse return;
        defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
        if (odbc.ok(odbc.SQLPrimaryKeysA(stmt, null, 0, null, 0, tz.ptr, odbc.SQL_NTS))) {
            var nb: [256]u8 = undefined;
            var kb: [16]u8 = undefined;
            var first = true;
            while (odbc.SQLFetch(stmt) == odbc.SQL_SUCCESS) {
                const cname = odbc.getText(stmt, 4, &nb) orelse continue; // COLUMN_NAME
                const kseq = odbc.getText(stmt, 5, &kb) orelse ""; // KEY_SEQ
                if (!first) try w.writeAll(", ");
                first = false;
                try w.writeAll("{\"column\": ");
                try writeJsonString(w, cname);
                try w.print(", \"seq\": {s}}}", .{numOrNull(kseq)});
            }
        }
    }
    try w.writeAll("],\n      \"indexes\": [");

    // indexes (segments grouped by index name; reveals unique/monotonic keys)
    {
        const stmt = newStmt(dbc) orelse return;
        defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
        if (odbc.ok(odbc.SQLStatisticsA(stmt, null, 0, null, 0, tz.ptr, odbc.SQL_NTS, odbc.SQL_INDEX_ALL, odbc.SQL_QUICK))) {
            var ib: [256]u8 = undefined;
            var nub: [16]u8 = undefined;
            var cb: [256]u8 = undefined;
            var first = true;
            while (odbc.SQLFetch(stmt) == odbc.SQL_SUCCESS) {
                const iname = odbc.getText(stmt, 6, &ib) orelse continue; // INDEX_NAME (null on table-stat rows)
                const nonuniq = odbc.getText(stmt, 4, &nub) orelse ""; // NON_UNIQUE
                const col = odbc.getText(stmt, 9, &cb) orelse ""; // COLUMN_NAME
                if (!first) try w.writeAll(",\n        ");
                if (first) try w.writeAll("\n        ");
                first = false;
                try w.writeAll("{\"index\": ");
                try writeJsonString(w, iname);
                try w.writeAll(", \"column\": ");
                try writeJsonString(w, col);
                try w.print(", \"non_unique\": {s}}}", .{numOrNull(nonuniq)});
            }
            if (!first) try w.writeAll("\n      ");
        }
    }
    try w.writeAll("]\n    }");
}

/// Emit a numeric string as-is if it parses, else JSON null. Keeps the output
/// valid JSON even when the driver returns blanks.
fn numOrNull(s: []const u8) []const u8 {
    if (s.len == 0) return "null";
    _ = std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch return "null";
    return std.mem.trim(u8, s, " ");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}
