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
DEFAULT_DB="fwdb"          # SQL db name; physical DB is "Freightware" (case-sensitive; -mdbg:Freightware)
DEFAULT_USER="fwsqllive"

echo "== FreightWare replica DB — connection =="
read -rp "Engine (progress | postgres | mysql | mssql) [progress]: " DB_ENGINE
DB_ENGINE="${DB_ENGINE:-progress}"
read -rp "Host [${DEFAULT_HOST}]: " DB_HOST
DB_HOST="${DB_HOST:-$DEFAULT_HOST}"
read -rp "Port [${DEFAULT_PORT}]: " DB_PORT
DB_PORT="${DB_PORT:-$DEFAULT_PORT}"
read -rp "Database name [${DEFAULT_DB}]: " DB_NAME
DB_NAME="${DB_NAME:-$DEFAULT_DB}"
read -rp "User [${DEFAULT_USER}]: " DB_USER
DB_USER="${DB_USER:-$DEFAULT_USER}"
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
    # Progress OpenEdge over JDBC (the DataDirect openedge.jar). Point OE_JDBC_JAR at
    # the driver (default ./openedge.jar). Java comes from PATH or the Homebrew openjdk.
    JAR="${OE_JDBC_JAR:-./openedge.jar}"
    JAVA_BIN="$(command -v java 2>/dev/null || echo /opt/homebrew/opt/openjdk/bin/java)"
    JAVAC_BIN="$(command -v javac 2>/dev/null || echo /opt/homebrew/opt/openjdk/bin/javac)"

    if [ ! -f "$JAR" ]; then
      echo "OpenEdge JDBC driver not found at '$JAR'." >&2
      echo "Copy openedge.jar from your OpenEdge server (\$DLC/java/openedge.jar) here," >&2
      echo "or set OE_JDBC_JAR=/path/to/openedge.jar, then re-run." >&2
      exit 1
    fi
    "$JAVA_BIN" -version >/dev/null 2>&1 || { echo "No Java runtime (brew install openjdk)." >&2; exit 1; }

    export FREIGHTWARE_DB_HOST="$DB_HOST" FREIGHTWARE_DB_PORT="$DB_PORT" \
           FREIGHTWARE_DB_NAME="$DB_NAME" FREIGHTWARE_DB_USER="$DB_USER" \
           FREIGHTWARE_DB_PASSWORD="$DB_PASS"

    WORK="$(mktemp -d)"
    cat > "$WORK/SchemaDump.java" <<'JAVA'
import java.sql.*;
public class SchemaDump {
  public static void main(String[] a) throws Exception {
    try { Class.forName("com.ddtek.jdbc.openedge.OpenEdgeDriver"); } catch (Throwable t) {}
    String h = System.getenv("FREIGHTWARE_DB_HOST"), p = System.getenv("FREIGHTWARE_DB_PORT"),
           d = System.getenv("FREIGHTWARE_DB_NAME"), u = System.getenv("FREIGHTWARE_DB_USER"),
           pw = System.getenv("FREIGHTWARE_DB_PASSWORD");
    String url = "jdbc:datadirect:openedge://" + h + ":" + p + ";databaseName=" + d;
    try (Connection c = DriverManager.getConnection(url, u, pw)) {
      DatabaseMetaData m = c.getMetaData();
      System.out.println("### TABLES (schema.table : type)");
      try (ResultSet r = m.getTables(null, null, "%", new String[]{"TABLE"})) {
        while (r.next())
          System.out.println(r.getString("TABLE_SCHEM") + "." + r.getString("TABLE_NAME")
            + " : " + r.getString("TABLE_TYPE"));
      }
      System.out.println();
      System.out.println("### COLUMNS (schema.table.column : type)");
      try (ResultSet r = m.getColumns(null, null, "%", "%")) {
        while (r.next())
          System.out.println(r.getString("TABLE_SCHEM") + "." + r.getString("TABLE_NAME")
            + "." + r.getString("COLUMN_NAME") + " : " + r.getString("TYPE_NAME"));
      }
    }
  }
}
JAVA
    "$JAVAC_BIN" -cp "$JAR" -d "$WORK" "$WORK/SchemaDump.java"
    "$JAVA_BIN" -cp "$JAR:$WORK" SchemaDump > "$OUT"
    rm -rf "$WORK"
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
