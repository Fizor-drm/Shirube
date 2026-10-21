# Scratch-only ACL check.
$ErrorActionPreference = 'Stop'
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot
$srvPath = Join-Path $devAuto 'Dashboard-Server.ps1'
$mgmtPath = Join-Path $devAuto 'Project-Management.ps1'
. $srvPath
. $mgmtPath

$base = Join-Path ([System.IO.Path]::GetTempPath()) 'PrivateAclTest'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

# Read-only ACL: only read rights -> must be rejected.
$roFile = Join-Path $scratch 'readonly.txt'
Set-Content -LiteralPath $roFile -Value 'x' -Encoding Ascii
$roAcl = Get-Acl -LiteralPath $roFile
$roAcl.SetAccessRuleProtection($true, $false)
foreach ($r in @($roAcl.Access)) { try { [void]$roAcl.RemoveAccessRule($r) } catch {} }
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$roAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'Read', 'Allow')))
Set-Acl -LiteralPath $roFile -AclObject $roAcl
Assert (-not (Test-MgmtPrivateFileAcl $roFile)) 'read-only ACL rejected'

# Private full-control ACL -> accepted.
$privFile = Join-Path $scratch 'private.txt'
Set-Content -LiteralPath $privFile -Value 'x' -Encoding Ascii
$privAcl = Get-Acl -LiteralPath $privFile
$privAcl.SetAccessRuleProtection($true, $false)
foreach ($r in @($privAcl.Access)) { try { [void]$privAcl.RemoveAccessRule($r) } catch {} }
foreach ($sid in @($me, (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
  $privAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
}
Set-Acl -LiteralPath $privFile -AclObject $privAcl
Assert (Test-MgmtPrivateFileAcl $privFile) 'full-control private ACL accepted'

Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
if ($failures.Count -gt 0) { Write-Host ("FAILURES: " + ($failures -join ', ')); exit 1 }
Write-Host 'ALL PRIVATE ACL CHECKS PASSED'
exit 0
