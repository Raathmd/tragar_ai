# freightware-schema-dump.ps1
#
# Run this on the WINDOWS machine that already connects Power BI to the FreightWare
# (Progress OpenEdge) database via ODBC. It reuses that existing ODBC driver/DSN to
# dump every table and column to CSV — no new installs (uses the built-in .NET
# ODBC provider). Read-only: it only reads the ODBC schema catalog.
#
# Usage (PowerShell):
#   # easiest — use the same DSN Power BI uses:
#   .\freightware-schema-dump.ps1 -Dsn "YourPowerBiOpenEdgeDsnName"
#
#   # or driverless (fill in the exact driver name from ODBC Data Source Admin):
#   .\freightware-schema-dump.ps1 -Driver "Progress OpenEdge 12.2 Driver"
#
# Then send me freightware-schema.csv + freightware-tables.csv.

param(
  [string]$Dsn    = "",
  [string]$Driver = "",
  [string]$DbHost = "tragar-db.dovetail.co.za",
  [int]   $Port   = 9007,
  [string]$Db     = "fwdb",
  [string]$User   = "fwsqllive"
)

$secure = Read-Host -AsSecureString "Password for $User"
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

if ($Dsn -ne "") {
  $connStr = "DSN=$Dsn;UID=$User;PWD=$pw"
} elseif ($Driver -ne "") {
  $connStr = "Driver={$Driver};HOST=$DbHost;PORT=$Port;DB=$Db;UID=$User;PWD=$pw"
} else {
  Write-Error "Pass -Dsn <name> (from ODBC Data Source Administrator) or -Driver '<driver name>'."
  exit 1
}

$conn = New-Object System.Data.Odbc.OdbcConnection($connStr)
$conn.Open()
Write-Host "Connected. Reading catalog..."

# All columns (schema/table/column/type) — the ODBC standard catalog view.
$conn.GetSchema("Columns") |
  Select-Object TABLE_SCHEM, TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, TYPE_NAME, COLUMN_SIZE |
  Sort-Object TABLE_SCHEM, TABLE_NAME, ORDINAL_POSITION |
  Export-Csv -Path freightware-schema.csv -NoTypeInformation -Encoding UTF8

# Table list.
$conn.GetSchema("Tables") |
  Select-Object TABLE_SCHEM, TABLE_NAME, TABLE_TYPE |
  Sort-Object TABLE_SCHEM, TABLE_NAME |
  Export-Csv -Path freightware-tables.csv -NoTypeInformation -Encoding UTF8

$conn.Close()
Write-Host "Done — wrote freightware-schema.csv and freightware-tables.csv"
