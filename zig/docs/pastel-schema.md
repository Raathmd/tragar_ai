# Pastel schema — findings & live-catalog dump procedure

## Target environment (confirmed)

| Thing | Value |
|---|---|
| Product | **Sage 50c Pastel Partner v19.4.7** |
| DB engine | **Actian Zen / Pervasive PSQL** (Btrieve files + relational catalog) |
| Sender host | **Windows 10 Pro 22H2** (64-bit OS) |
| ODBC driver | **Pervasive ODBC Client Interface** — **32-bit** (so the sender binary is `x86-windows`, even on 64-bit Windows) |
| Catalog | DDFs in the company data folder: `FILE.DDF`, `FIELD.DDF`, `INDEX.DDF` |

The 32-bit driver is the reason for the `x86-windows` build: a 64-bit process
cannot load a 32-bit ODBC driver. Configure the DSN in the **32-bit** ODBC
Administrator: `C:\Windows\SysWOW64\odbcad32.exe` (the default
`Control Panel → ODBC` on 64-bit Windows is the 64-bit one and will not show the
Pastel driver).

## Tables (documented names — verified against Sage KB)

| ODBC table | .dat file | Class | Key (as documented) | Notes |
|---|---|---|---|---|
| `HistoryHeader` | `acchisth.dat` | transaction | `DocumentType` + `DocumentNumber` | posted document headers; **excludes** receipts/payments/GL journals |
| `HistoryLines` | `acchistl.dat` | transaction | `DocumentType` + `DocumentNumber` (+ line) | document line detail |
| `OpenItem` | — | transaction | TBD | receipts/payments/allocations (the bits HistoryHeader omits) |
| `CustomerMaster` | — | master | `CustomerCode` (space-padded) | |
| `SupplierMaster` | — | master | `SupplierCode` (TBD exact col) | |
| `InventoryMaster` | — | master | `ItemCode` (TBD exact col) | |

These names go into `config.toml`; **column** names and the incremental
**watermark** still need live confirmation (below).

## Watermark — DECIDED: monotonic-if-exists, else per-type (confirm vs dump)

The spec's incremental rule was *"pull WHERE record-number > watermark"*, which
assumes each transaction table has a **single monotonically-increasing record
id**. Pastel Partner's history tables are instead keyed by the **composite
`(DocumentType, DocumentNumber)`**, and `DocumentNumber` is sequential only
*within* a document type — there is no *documented* single global autoincrement
column.

**Decision (final pick confirmed against the dump):**
1. If the dump reveals a real monotonic column on a history table → watermark on
   it (closest to the original spec).
2. Otherwise → **composite watermark per `DocumentType`**: track the last
   `DocumentNumber` per type and pull `> last` per type.
3. Last resort, if neither holds → snapshot + per-row hash (as masters use).

Master tables always use snapshot + per-row hash. `class` drives the receiver's
upsert semantics; `keys` drive `ON CONFLICT`. The `INDEX_NAME`/`NON_UNIQUE`
columns in the dump's `indexes` arrays are exactly what tell us whether case (1)
applies — that's why `schema-dump` includes `SQLStatistics`.

## How to dump THIS install's catalog (so we lock columns + keys)

Any one of these, run on the Windows 10 box against the Pastel company database.
Send back the output and we finalize `config.toml`.

### Option A — Zen Control Center (GUI, easiest)
1. Open **Actian/Pervasive Zen Control Center** (ships with PSQL).
2. Connect to the Pastel database (or add it pointing at the company data folder
   + its DDFs).
3. Expand **Tables** → for each of `HistoryHeader`, `HistoryLines`, `OpenItem`,
   `CustomerMaster`, `SupplierMaster`, `InventoryMaster`: export/screenshot the
   **column list** (name + type) and the **Indexes** tab (the primary/segment
   keys). The Indexes tab is what reveals any single-column monotonic key.

### Option B — SQL against the relational catalog
In the Zen Control Center SQL editor (or any tool on the Pastel DSN):

```sql
-- all user tables
SELECT Xf$Name FROM X$File WHERE Xf$Name NOT LIKE 'X$%' ORDER BY Xf$Name;

-- columns of one table (repeat per table of interest)
SELECT e.Xe$Name AS column_name, e.Xe$DataType AS type_code,
       e.Xe$Size AS size, e.Xe$Offset AS offset
FROM   X$Field e JOIN X$File f ON e.Xe$File = f.Xf$Id
WHERE  f.Xf$Name = 'HistoryHeader'
ORDER  BY e.Xe$Offset;

-- index segments (reveals keys / any monotonic single-col index)
SELECT f.Xf$Name AS table_name, i.Xi$Number AS index_no,
       e.Xe$Name AS column_name, i.Xi$Part AS segment, i.Xi$Flags AS flags
FROM   X$Index i
       JOIN X$File  f ON i.Xi$File  = f.Xf$Id
       JOIN X$Field e ON i.Xi$Field = e.Xe$Id
WHERE  f.Xf$Name IN ('HistoryHeader','HistoryLines','OpenItem',
                     'CustomerMaster','SupplierMaster','InventoryMaster')
ORDER  BY f.Xf$Name, i.Xi$Number, i.Xi$Part;
```

### Option C — ODBC catalog calls
If easier, point Excel **Data → Get Data → From ODBC** at the Pastel DSN; the
Navigator lists every table, and selecting one shows its columns. Export the
table list + the six tables' columns.

### Option D — the `schema-dump` utility (built — recommended)

`zig/schema-dump/` is a tiny x86-windows tool (hand-declared `odbc32` bindings:
`SQLTables`/`SQLColumns`/`SQLPrimaryKeys`/`SQLStatistics` → JSON). It uses the
exact ODBC path the sender will, so running it also validates the DSN end-to-end.

```bash
# build (any machine with Zig 0.16 — cross-compiles to a 32-bit .exe):
cd zig/schema-dump && zig build          # -> zig-out/bin/schema-dump.exe

# run on the Windows 10 box, against the SAME 32-bit DSN the sender will use:
schema-dump.exe "DSN=PastelData" > schema.json
#   or DSN-less:
schema-dump.exe "Driver={Pervasive ODBC Client Interface};ServerName=...;DBQ=..." > schema.json
```

It always lists every `TABLE`, and details columns + primary key + index
segments for the built-in Pastel set (override by passing table names as extra
args). Send `schema.json` back and we lock `config.toml`.
