#!/usr/bin/env bash
#
# freightware-db-explore.sh
#
# Connect to the parallel FreightWare database (the read replica that FreightWare
# updates), store the credentials in .env, and dump its schema so we can see how
# to read data directly for anything the API doesn't expose.
#
# Usage:
#   ./freightware-db-explore.sh
#
# It prompts for the connection, saves the FREIGHTWARE_DB_* vars to .env (which is
# gitignored), then writes the schema to freightware-schema.txt. Read-only — it
# only introspects information_schema / catalog tables; it never writes data.
#
# Requires the client for your engine on PATH:
#   postgres -> psql     mysql -> mysql     mssql -> sqlcmd
#
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
OUT="${OUT:-freightware-schema.txt}"

DEFAULT_HOST="tragar-db.dovetail.co.za"
DEFAULT_PORT="9007"

echo "== FreightWare replica DB — connection =="
read -rp "Engine (progress | postgres | mysql | mssql) [progress]: " DB_ENGINE
DB_ENGINE="${DB_ENGINE:-progress}"
read -rp "Host [${DEFAULT_HOST}]: " DB_HOST
DB_HOST="${DB_HOST:-$DEFAULT_HOST}"
read -rp "Port [${DEFAULT_PORT}]: " DB_PORT
DB_PORT="${DB_PORT:-$DEFAULT_PORT}"
read -rp "Database name: " DB_NAME
read -rp "User: " DB_USER
read -rsp "Password: " DB_PASS
echo

# --- store the credentials in .env (replacing any earlier FREIGHTWARE_DB_* block) ---
touch "$ENV_FILE"
grep -v '^FREIGHTWARE_DB_' "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
{
  echo "FREIGHTWARE_DB_ENGINE=$DB_ENGINE"
  echo "FREIGHTWARE_DB_HOST=$DB_HOST"
  echo "FREIGHTWARE_DB_PORT=$DB_PORT"
  echo "FREIGHTWARE_DB_NAME=$DB_NAME"
  echo "FREIGHTWARE_DB_USER=$DB_USER"
  echo "FREIGHTWARE_DB_PASSWORD=$DB_PASS"
} >> "${ENV_FILE}.tmp"
mv "${ENV_FILE}.tmp" "$ENV_FILE"
echo "Saved FREIGHTWARE_DB_* to $ENV_FILE (gitignored)."

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing client '$1' on PATH — install it and re-run." >&2
    exit 1
  }
}

echo "== Introspecting schema -> $OUT =="

case "$DB_ENGINE" in
  progress)
    # Progress OpenEdge. Its SQL catalog is in the SYSPROGRESS schema; user tables
    # live in the PUB schema. OpenEdge is NOT reachable with psql — it needs one of:
    #   - sqlexp        (ships with an OpenEdge client install)
    #   - isql          (unixODBC + the Progress DataDirect OpenEdge ODBC driver)
    #   - a JDBC client (openedge.jar + Java)
    # none of which are standard on macOS. Introspection queries, once wired:
    #   tables : SELECT "_File-Name" FROM PUB."_File" WHERE "_File-Number" > 0;
    #   columns: SELECT "_File-Name","_Field-Name","_Data-Type" FROM PUB."_Field" f
    #            JOIN PUB."_File" t ON t.RECID = f."_File-recid";
    echo
    echo "Progress OpenEdge selected — credentials saved to $ENV_FILE."
    echo "OpenEdge needs an OpenEdge SQL client (sqlexp / ODBC isql / JDBC), none of"
    echo "which ship on macOS by default. Tell me which one you have (or can install)"
    echo "and I'll finalise the introspection for it. See the comments in this script."
    exit 0
    ;;

  postgres)
    need psql
    export PGPASSWORD="$DB_PASS"
    PSQL=(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -X -A -F $'\t' --pset footer=off -t)
    {
      echo "### TABLES (schema.table — approx live rows, largest first)"
      "${PSQL[@]}" -c "SELECT schemaname||'.'||relname||E'\t'||n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"
      echo
      echo "### COLUMNS (schema.table.column : type)"
      "${PSQL[@]}" -c "SELECT table_schema||'.'||table_name||'.'||column_name||' : '||data_type FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog','information_schema') ORDER BY table_schema, table_name, ordinal_position;"
    } > "$OUT"
    ;;

  mysql)
    need mysql
    MYSQL=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "-p$DB_PASS" -N -B "$DB_NAME")
    {
      echo "### TABLES (table — approx rows, largest first)"
      "${MYSQL[@]}" -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$DB_NAME' ORDER BY table_rows DESC;"
      echo
      echo "### COLUMNS (table.column : type)"
      "${MYSQL[@]}" -e "SELECT CONCAT(table_name,'.',column_name,' : ',column_type) FROM information_schema.columns WHERE table_schema='$DB_NAME' ORDER BY table_name, ordinal_position;"
    } > "$OUT"
    ;;

  mssql)
    need sqlcmd
    SQLCMD=(sqlcmd -S "$DB_HOST,$DB_PORT" -U "$DB_USER" -P "$DB_PASS" -d "$DB_NAME" -h -1 -W -s $'\t')
    {
      echo "### TABLES (schema.table — approx rows, largest first)"
      "${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT s.name+'.'+t.name, SUM(p.rows) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1) GROUP BY s.name,t.name ORDER BY SUM(p.rows) DESC;"
      echo
      echo "### COLUMNS (schema.table.column : type)"
      "${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT table_schema+'.'+table_name+'.'+column_name+' : '+data_type FROM information_schema.columns ORDER BY table_schema, table_name, ordinal_position;"
    } > "$OUT"
    ;;

  *)
    echo "Unknown engine '$DB_ENGINE' (use postgres | mysql | mssql)." >&2
    exit 1
    ;;
esac

echo "Done — schema written to $OUT"
echo "---- top tables by row count ----"
sed -n '/### TABLES/,/^$/p' "$OUT" | sed '1d;/^$/d' | head -25
