@echo off
rem Shirube management dashboard launcher (AppData trusted copy only)
rem Trust boundary: the repository directory may be writable by other local users (Modify),
rem so code there is NEVER executed directly. Only the protected copy under
rem %LOCALAPPDATA%\Shirube\.automation is executed. This bat in the repo is the
rem master for deployment; a parent copies it to AppData after review.
rem No dev fallback. If the AppData set is missing, exit with placement error.
rem r3: health 200 alone is not trusted. Verify state PID+start+TCP+health instance before token use.
rem r7: Run only fixed absolute paths to prevent CWD hijack. powershell under SystemRoot; wscript is chosen by Verify-Dashboard.ps1.
rem r8: one PowerShell startup verifies, starts when needed, and waits for readiness.
rem Browser start keeps OS default. health is fixed 127.0.0.1.
setlocal
set PORT=18721
set AUTO=%LOCALAPPDATA%\Shirube\.automation
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe

if not exist "%AUTO%\Dashboard-Server.ps1" goto :notdeployed
if not exist "%AUTO%\Run-Dashboard.vbs" goto :notdeployed
if not exist "%AUTO%\Verify-Dashboard.ps1" goto :notdeployed
goto :verify

:notdeployed
echo [Shirube] Dashboard files are not placed in AppData: %AUTO%
echo The repo side is the master. Ask the protector to place Dashboard-Server.ps1 and Run-Dashboard.vbs and Verify-Dashboard.ps1 and this launcher to AppData. Code in the repository directory is never executed directly.
pause
exit /b 1

:verify
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%AUTO%\Verify-Dashboard.ps1" -AutoDir "%AUTO%" -Port %PORT% -EnsureRunning -ServerScript "%AUTO%\Run-Dashboard.vbs" -WaitSec 20 >nul 2>&1
if not errorlevel 1 goto :openbrowser
echo [Shirube] Dashboard could not be verified or started on 127.0.0.1:%PORT%.
echo Another service may be using the port. Token was not sent.
echo Check the owner of %PORT% with Task Manager and netstat -ano.
echo Check %AUTO%\logs and dashboard.state.json.
pause
exit /b 1

:openbrowser
set TOKEN=
if exist "%AUTO%\dashboard.token" for /f "usebackq delims=" %%t in ("%AUTO%\dashboard.token") do set TOKEN=%%t
if "%TOKEN%"=="" (
  echo [Shirube] Token is not ready yet. Wait and retry.
  pause
  exit /b 1
)
start "" "http://127.0.0.1:%PORT%/?token=%TOKEN%"
endlocal
