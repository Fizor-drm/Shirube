' Run-Dashboard.vbs - hidden background host for Dashboard-Server.ps1.
' Double-launch reuse is handled by the batch (health check before start).
' Fire-and-forget: do not wait, so the dashboard survives the launcher.
Option Explicit
Dim fso, sh, dir, ps, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = fso.BuildPath(dir, "Dashboard-Server.ps1")
cmd = """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps & """"
Call sh.Run(cmd, 0, False)
