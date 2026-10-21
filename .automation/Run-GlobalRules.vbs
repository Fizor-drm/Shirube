' Run-GlobalRules.vbs - hidden launcher for Sync-GlobalRules.ps1 (Task Scheduler).
' Task starts wscript.exe (windowless); WScript.Shell.Run hides PowerShell (0)
' and waits (True), then returns its exit code to the task via WScript.Quit.
Option Explicit
Dim fso, sh, dir, ps, cmd, rc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = fso.BuildPath(dir, "Sync-GlobalRules.ps1")
cmd = """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps & """"
rc = sh.Run(cmd, 0, True)
WScript.Quit rc
