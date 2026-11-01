@echo off
rem Windows launcher for windowscomputeinfo.ps1
rem
rem Double-click this file to run the report: -ExecutionPolicy Bypass is used so
rem it works even on machines whose policy is Restricted. Arguments are passed
rem through to the PowerShell script (-SkipAntivirus, -SkipSecureBoot). The
rem window stays open for reading unless NO_PAUSE=1 is set, which is what
rem automation should use:
rem
rem     set NO_PAUSE=1 && windowscomputeinfo.cmd
rem
rem Every statement is kept on a single line: this file is stored with LF line
rem endings, and cmd.exe only parses multi-line blocks and labels reliably when
rem they use CRLF.
setlocal

set "REPORT_SCRIPT=%~dp0windowscomputeinfo.ps1"

if not exist "%REPORT_SCRIPT%" echo [!] windowscomputeinfo.ps1 was not found next to this launcher. Keep both files in the same folder.
if not exist "%REPORT_SCRIPT%" pause
if not exist "%REPORT_SCRIPT%" exit /b 1

powershell -NoProfile -ExecutionPolicy Bypass -File "%REPORT_SCRIPT%" %*
set "SCRIPT_EXIT=%ERRORLEVEL%"

if /i not "%NO_PAUSE%"=="1" pause
exit /b %SCRIPT_EXIT%
