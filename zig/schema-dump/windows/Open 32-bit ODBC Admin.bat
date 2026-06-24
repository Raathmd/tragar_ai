@echo off
REM ===========================================================================
REM  Open 32-bit ODBC Admin
REM
REM  Pastel's database driver is 32-bit, so its data source (DSN) must be
REM  created in the 32-bit ODBC Administrator - NOT the normal one in the
REM  Control Panel (that one is 64-bit and will not show the Pastel driver).
REM
REM  Double-click this to open the correct (32-bit) ODBC Administrator.
REM  In it:  go to the "System DSN" tab  ->  Add  ->  pick the Pastel /
REM  Pervasive / Actian Zen driver  ->  point it at your company data  ->
REM  give it a name (remember the name) and click OK.
REM  Then run "Dump Pastel Schema.bat" and type that name.
REM ===========================================================================
echo Opening the 32-bit ODBC Administrator...
start "" "%WINDIR%\SysWOW64\odbcad32.exe"
