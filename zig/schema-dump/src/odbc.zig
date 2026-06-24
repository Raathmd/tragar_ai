//! Minimal ODBC (Win32 / x86) bindings for the schema-dump tool and, later, the
//! sender's reader. Hand-declared against the stable ODBC ABI instead of
//! @cImport-ing <sql.h>/<windows.h>: translate-c chokes on 32-bit winnt.h
//! (PCONTEXT), and explicit externs are version-stable across Zig releases.
//!
//! ⚠️ Win32 only: SQLLEN/SQLULEN are 32-bit here. A 64-bit build would need
//! 64-bit SQLLEN — but the Pastel driver is 32-bit, so the binary is x86-windows.

const std = @import("std");

// ── Core types ──────────────────────────────────────────────────────────────
pub const SQLHANDLE = ?*anyopaque;
pub const SQLHENV = SQLHANDLE;
pub const SQLHDBC = SQLHANDLE;
pub const SQLHSTMT = SQLHANDLE;
pub const SQLHWND = ?*anyopaque;
pub const SQLSMALLINT = c_short;
pub const SQLUSMALLINT = c_ushort;
pub const SQLINTEGER = c_int;
pub const SQLRETURN = SQLSMALLINT;
pub const SQLLEN = c_long; // 32-bit on Win32
pub const SQLULEN = c_ulong;
pub const SQLPOINTER = ?*anyopaque;
pub const SQLCHAR = u8;

// ── Constants ────────────────────────────────────────────────────────────────
pub const SQL_HANDLE_ENV: SQLSMALLINT = 1;
pub const SQL_HANDLE_DBC: SQLSMALLINT = 2;
pub const SQL_HANDLE_STMT: SQLSMALLINT = 3;
pub const SQL_NULL_HANDLE: SQLHANDLE = null;

pub const SQL_SUCCESS: SQLRETURN = 0;
pub const SQL_SUCCESS_WITH_INFO: SQLRETURN = 1;
pub const SQL_NO_DATA: SQLRETURN = 100;
pub const SQL_ERROR: SQLRETURN = -1;
pub const SQL_INVALID_HANDLE: SQLRETURN = -2;

pub const SQL_ATTR_ODBC_VERSION: SQLINTEGER = 200;
pub const SQL_OV_ODBC3: usize = 3;
pub const SQL_DRIVER_NOPROMPT: SQLUSMALLINT = 0;

pub const SQL_NTS: SQLSMALLINT = -1;
pub const SQL_C_CHAR: SQLSMALLINT = 1;
pub const SQL_NULL_DATA: SQLLEN = -1;
pub const SQL_CLOSE: SQLUSMALLINT = 0;

// SQLStatistics fUnique / fAccuracy
pub const SQL_INDEX_UNIQUE: SQLUSMALLINT = 0;
pub const SQL_INDEX_ALL: SQLUSMALLINT = 1;
pub const SQL_QUICK: SQLUSMALLINT = 0;
pub const SQL_ENSURE: SQLUSMALLINT = 1;
// SQLStatistics TYPE column value meaning "table statistics, not an index"
pub const SQL_TABLE_STAT: i64 = 0;

// ── Functions (ANSI 'A' variants; __stdcall via .winapi) ─────────────────────
pub extern "odbc32" fn SQLAllocHandle(HandleType: SQLSMALLINT, InputHandle: SQLHANDLE, OutputHandle: *SQLHANDLE) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLFreeHandle(HandleType: SQLSMALLINT, Handle: SQLHANDLE) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLSetEnvAttr(EnvironmentHandle: SQLHENV, Attribute: SQLINTEGER, Value: SQLPOINTER, StringLength: SQLINTEGER) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLDriverConnectA(hdbc: SQLHDBC, hwnd: SQLHWND, szConnStrIn: [*]const SQLCHAR, cbConnStrIn: SQLSMALLINT, szConnStrOut: ?[*]SQLCHAR, cbConnStrOutMax: SQLSMALLINT, pcbConnStrOut: ?*SQLSMALLINT, fDriverCompletion: SQLUSMALLINT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLDisconnect(ConnectionHandle: SQLHDBC) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLTablesA(stmt: SQLHSTMT, cat: ?[*]const SQLCHAR, ncat: SQLSMALLINT, sch: ?[*]const SQLCHAR, nsch: SQLSMALLINT, tbl: ?[*]const SQLCHAR, ntbl: SQLSMALLINT, typ: ?[*]const SQLCHAR, ntyp: SQLSMALLINT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLColumnsA(stmt: SQLHSTMT, cat: ?[*]const SQLCHAR, ncat: SQLSMALLINT, sch: ?[*]const SQLCHAR, nsch: SQLSMALLINT, tbl: ?[*]const SQLCHAR, ntbl: SQLSMALLINT, col: ?[*]const SQLCHAR, ncol: SQLSMALLINT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLPrimaryKeysA(stmt: SQLHSTMT, cat: ?[*]const SQLCHAR, ncat: SQLSMALLINT, sch: ?[*]const SQLCHAR, nsch: SQLSMALLINT, tbl: ?[*]const SQLCHAR, ntbl: SQLSMALLINT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLStatisticsA(stmt: SQLHSTMT, cat: ?[*]const SQLCHAR, ncat: SQLSMALLINT, sch: ?[*]const SQLCHAR, nsch: SQLSMALLINT, tbl: ?[*]const SQLCHAR, ntbl: SQLSMALLINT, fUnique: SQLUSMALLINT, fAccuracy: SQLUSMALLINT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLFetch(stmt: SQLHSTMT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLGetData(stmt: SQLHSTMT, col: SQLUSMALLINT, targetType: SQLSMALLINT, target: SQLPOINTER, bufLen: SQLLEN, strLenOrInd: ?*SQLLEN) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLFreeStmt(stmt: SQLHSTMT, option: SQLUSMALLINT) callconv(.winapi) SQLRETURN;
pub extern "odbc32" fn SQLGetDiagRecA(handleType: SQLSMALLINT, handle: SQLHANDLE, recNumber: SQLSMALLINT, sqlState: ?[*]SQLCHAR, nativeError: ?*SQLINTEGER, msgText: ?[*]SQLCHAR, bufLen: SQLSMALLINT, textLen: ?*SQLSMALLINT) callconv(.winapi) SQLRETURN;

// ── Helpers ──────────────────────────────────────────────────────────────────
pub fn ok(rc: SQLRETURN) bool {
    return rc == SQL_SUCCESS or rc == SQL_SUCCESS_WITH_INFO;
}

/// Read column `col` of the current row as text into `buf`. Returns null on a
/// SQL NULL, otherwise the value slice (sans the driver's null terminator).
pub fn getText(stmt: SQLHSTMT, col: SQLUSMALLINT, buf: []u8) ?[]const u8 {
    var ind: SQLLEN = 0;
    const rc = SQLGetData(stmt, col, SQL_C_CHAR, @ptrCast(buf.ptr), @intCast(buf.len), &ind);
    if (!ok(rc)) return null;
    if (ind == SQL_NULL_DATA) return null;
    const n: usize = if (ind < 0) 0 else @min(@as(usize, @intCast(ind)), buf.len - 1);
    return buf[0..n];
}

/// Format the first diagnostic record for `handle` into `buf` (e.g. for errors).
pub fn diag(handleType: SQLSMALLINT, handle: SQLHANDLE, buf: []u8) []const u8 {
    var state: [6]SQLCHAR = undefined;
    var native: SQLINTEGER = 0;
    var msg: [512]SQLCHAR = undefined;
    var msg_len: SQLSMALLINT = 0;
    const rc = SQLGetDiagRecA(handleType, handle, 1, &state, &native, &msg, msg.len, &msg_len);
    if (!ok(rc)) return "no diagnostic";
    const mlen: usize = if (msg_len < 0) 0 else @min(@as(usize, @intCast(msg_len)), msg.len);
    return std.fmt.bufPrint(buf, "[{s}] {s}", .{ state[0..5], msg[0..mlen] }) catch "diag too long";
}
