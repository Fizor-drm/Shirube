@echo off
rem Shirube management dashboard launcher (AppData trusted copy only)
rem Trust boundary: the repository directory may be writable by other local users (Modify),
rem so code there is NEVER executed directly. Only the protected copy under
rem %LOCALAPPDATA%\Shirube\.automation is executed. This bat in the repo is the
rem master for deployment; a parent copies it to AppData after review.
rem No dev fallback. If the AppData set is missing, exit with placement error.
rem r3: health 200 alone is not trusted. Verify state PID+start+TCP+health instance before token use.
rem r7: Run only fixed absolute paths to prevent CWD hijack. powershell/wscript/timeout under SystemRoot.
rem Browser start keeps OS default. health is fixed 127.0.0.1.
setlocal
set PORT=18721
set AUTO=%LOCALAPPDATA%\Shirube\.automation
set HEALTH=http://127.0.0.1:%PORT%/health
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
set WS=%SystemRoot%\System32\wscript.exe
set TO=%SystemRoot%\System32\timeout.exe

if not exist "%AUTO%\Dashboard-Server.ps1" goto :notdeployed
if not exist "%AUTO%\Run-Dashboard.vbs" goto :notdeployed
if not exist "%AUTO%\Verify-Dashboard.ps1" goto :notdeployed
goto :checkhealth

:notdeployed
echo [Shirube] Dashboard files are not placed in AppData: %AUTO%
echo The repo side is the master. Ask the protector to place Dashboard-Server.ps1 and Run-Dashboard.vbs and Verify-Dashboard.ps1 and this launcher to AppData. Code in the repository directory is never executed directly.
pause
exit /b 1

:checkhealth
"%PS%" -NoProfile -NonInteractive -Command "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 '%HEALTH%').StatusCode } catch { exit 1 }" >nul 2>&1
if errorlevel 1 goto :start
goto :verify

:verify
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%AUTO%\Verify-Dashboard.ps1" -AutoDir "%AUTO%" -Port %PORT% >nul 2>&1
if not errorlevel 1 goto :openbrowser
echo [Shirube] 127.0.0.1:%PORT% could not be confirmed as Shirube.
echo Another service may be using the port. Token was not sent.
echo Check the owner of %PORT% with Task Manager and netstat -ano.
pause
exit /b 1

:start
start "" /min "%WS%" //B //Nologo "%AUTO%\Run-Dashboard.vbs"
rem single in-process cold-readiness wait (Verify-Dashboard.ps1 -WaitSec); no repeated PS startup
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%AUTO%\Verify-Dashboard.ps1" -AutoDir "%AUTO%" -Port %PORT% -WaitSec 20 -PollMs 250 >nul 2>&1
if not errorlevel 1 goto :openbrowser
echo [Shirube] Dashboard start confirmation failed. Token was not sent.
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
