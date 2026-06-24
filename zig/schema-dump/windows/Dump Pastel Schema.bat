@echo off
REM ===========================================================================
REM  Dump Pastel Schema
REM
REM  Double-click this file. It connects to your Pastel data through ODBC and
REM  saves a file called  schema.json  in this same folder. When it is done,
REM  email that schema.json file back to raathmd@gmail.com.
REM
REM  You do NOT need to install anything. If something goes wrong the window
REM  stays open and shows a plain-English message.
REM ===========================================================================
setlocal enabledelayedexpansion
title Dump Pastel Schema
color 0B

REM --- always work from the folder this script lives in ----------------------
cd /d "%~dp0"

set "OUTFILE=%~dp0schema.json"

REM --- find the program to run (prefer a fresh build if one exists) ----------
set "EXE="
if exist "%~dp0..\zig-out\bin\schema-dump.exe" set "EXE=%~dp0..\zig-out\bin\schema-dump.exe"
if not defined EXE if exist "%~dp0schema-dump.exe" set "EXE=%~dp0schema-dump.exe"
if not defined EXE (
  echo.
  echo  ERROR: Could not find schema-dump.exe next to this script.
  echo  Make sure you copied the WHOLE folder, not just this one file.
  echo.
  goto :theend
)

echo.
echo  ============================================================
echo    PASTEL SCHEMA DUMP
echo  ============================================================
echo.
echo  This will read the structure of your Pastel database and
echo  save it to:
echo.
echo      %OUTFILE%
echo.
echo  Nothing in Pastel is changed. This only reads.
echo.

REM --- show the 32-bit ODBC data sources (DSNs) found on this PC -------------
echo  ------------------------------------------------------------
echo   ODBC data sources found on this computer:
echo  ------------------------------------------------------------
set "FOUNDANY="
for /f "tokens=1,*" %%A in ('reg query "HKLM\SOFTWARE\WOW6432Node\ODBC\ODBC.INI\ODBC Data Sources" 2^>nul ^| findstr /r /c:"REG_SZ"') do (
  echo     - %%A
  set "FOUNDANY=1"
)
for /f "tokens=1,*" %%A in ('reg query "HKCU\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources" 2^>nul ^| findstr /r /c:"REG_SZ"') do (
  echo     - %%A
  set "FOUNDANY=1"
)
if not defined FOUNDANY (
  echo     (none found)
  echo.
  echo   No 32-bit ODBC data source is set up yet. To create one, run
  echo   "Open 32-bit ODBC Admin.bat" in this folder, add a System DSN
  echo   that points at your Pastel company, then run this script again.
)
echo  ------------------------------------------------------------
echo.

REM --- ask which data source to use ------------------------------------------
echo  Type the data-source (DSN) name from the list above and press Enter.
echo  (If you were given a full connection string, you can paste that instead.)
echo.
set "CONN="
set /p "CONN=  Data source / connection string: "

if "!CONN!"=="" (
  echo.
  echo  Nothing entered - cancelled. Run the script again when ready.
  goto :theend
)

REM --- if it has an = sign treat it as a full connection string, else a DSN ---
echo !CONN!| find "=" >nul
if errorlevel 1 (
  set "CONNSTR=DSN=!CONN!"
) else (
  set "CONNSTR=!CONN!"
)

echo.
echo  Connecting with: !CONNSTR!
echo  Please wait...
echo.

REM --- run it: JSON goes to the file, any error message shows on screen -------
"%EXE%" "!CONNSTR!" > "%OUTFILE%"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ============================================================
  echo    SOMETHING WENT WRONG  (code %RC%)
  echo  ============================================================
  echo.
  echo  The most common cause is the wrong data-source name, or the
  echo  data source being set up under 64-bit instead of 32-bit ODBC.
  echo.
  echo  Tips:
  echo    - Re-check the name spelling against the list above.
  echo    - Pastel's driver is 32-bit, so the DSN must be created in
  echo      the 32-bit ODBC admin ("Open 32-bit ODBC Admin.bat").
  echo    - Any error detail shown above this box can be sent to us.
  echo.
  del "%OUTFILE%" >nul 2>&1
  goto :theend
)

echo  ============================================================
echo    SUCCESS
echo  ============================================================
echo.
echo  Saved:  %OUTFILE%
echo.
echo  Next step: email that schema.json file to  raathmd@gmail.com
echo.
echo  (Opening the folder for you...)
explorer /select,"%OUTFILE%"

:theend
echo.
echo  Press any key to close this window.
pause >nul
endlocal
