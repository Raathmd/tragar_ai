import java.sql.*;

/** Read-only ad-hoc SELECT against the FreightWare OpenEdge replica.
 *  SQL comes from env FWDB_SQL. Prints columns + up to FWDB_LIMIT rows (default 50). */
public class Query {
  public static void main(String[] args) throws Exception {
    String host = env("FWDB_HOST", "tragar-db.dovetail.co.za");
    String port = env("FWDB_PORT", "9007");
    String db   = env("FWDB_NAME", "fwdb");
    String user = env("FWDB_USER", "fwsqllive");
    String pw   = System.getenv("FWDB_PW");
    String sql  = System.getenv("FWDB_SQL");
    int limit   = Integer.parseInt(env("FWDB_LIMIT", "50"));
    if (pw == null || pw.isEmpty()) { System.err.println("FWDB_PW not set"); System.exit(2); }
    if (sql == null || sql.isEmpty()) { System.err.println("FWDB_SQL not set"); System.exit(2); }

    String url = "jdbc:datadirect:openedge://" + host + ":" + port + ";databaseName=" + db;
    Class.forName("com.ddtek.jdbc.openedge.OpenEdgeDriver");
    try (Connection c = DriverManager.getConnection(url, user, pw);
         Statement st = c.createStatement()) {
      st.setMaxRows(limit);
      try (ResultSet rs = st.executeQuery(sql)) {
        ResultSetMetaData m = rs.getMetaData();
        int n = m.getColumnCount();
        StringBuilder h = new StringBuilder();
        for (int i = 1; i <= n; i++) h.append(i > 1 ? " | " : "").append(m.getColumnLabel(i));
        System.out.println(h);
        System.out.println("-".repeat(h.length()));
        int rows = 0;
        while (rs.next()) {
          StringBuilder b = new StringBuilder();
          for (int i = 1; i <= n; i++) {
            String v = rs.getString(i);
            b.append(i > 1 ? " | " : "").append(v == null ? "" : v);
          }
          System.out.println(b);
          rows++;
        }
        System.out.println("(" + rows + " rows)");
      }
    }
  }
  static String env(String k, String d) { String v = System.getenv(k); return (v == null || v.isEmpty()) ? d : v; }
}
