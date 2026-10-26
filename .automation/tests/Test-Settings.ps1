# Test-Settings.ps1 - self-checks for Settings.ps1 / settings.json (personal settings).
# Scratch-only. The real .automation/settings.json is never read or written:
# Settings.ps1 is copied next to a scratch settings.json and dot-sourced there.
$ErrorActionPreference = 'Stop'
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot

$testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'SettingsTest'
New-Item -ItemType Directory -Force -Path $testBase | Out-Null
$scratch = Join-Path $testBase ('run-' + [System.Guid]::NewGuid().ToString('N'))
$auto = Join-Path $scratch 'auto'
New-Item -ItemType Directory -Force -Path $auto | Out-Null

try {
  Copy-Item -LiteralPath (Join-Path $devAuto 'Settings.ps1') -Destination (Join-Path $auto 'Settings.ps1') -Force
  . (Join-Path $auto 'Settings.ps1')
  $settingsPath = Get-ShirubeSettingsPath
  function Set-Settings([string]$Text) { Set-Content -LiteralPath $settingsPath -Value $Text -Encoding UTF8 }

  # S0: settings.json は Settings.ps1 と同じ階層。無ければパスだけ返す。
  Assert ($settingsPath -ceq (Join-Path $auto 'settings.json')) 'S0 settings path sits next to Settings.ps1'
  Assert (-not (Test-Path -LiteralPath $settingsPath)) 'S0 missing file still resolves a path'

  # S1: settings.json が無いときは既定値
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'Shirube Global Auto Sync') 'S1 no file: global task default'
  Assert ((Get-ShirubeSetting -Name 'taskNameProject' -Default 'Shirube Project Auto Sync') -ceq 'Shirube Project Auto Sync') 'S1 no file: project task default'
  Assert ((Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0') -ceq '32.0.0') 'S1 no file: rulesync version default'

  # S2: 値があれば上書き値を返す
  Set-Settings '{"taskNameGlobal":"Custom Global Task","taskNameProject":"Custom Project Task","rulesyncVersion":"1.2.3"}'
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'Custom Global Task') 'S2 override global task name'
  Assert ((Get-ShirubeSetting -Name 'taskNameProject' -Default 'Shirube Project Auto Sync') -ceq 'Custom Project Task') 'S2 override project task name'
  Assert ((Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0') -ceq '1.2.3') 'S2 override rulesync version'

  # S3: JSON不正でも例外を投げず既定値
  Set-Settings '{"taskNameGlobal": '
  $s3Threw = $false
  $s3Val = ''
  try { $s3Val = Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync' } catch { $s3Threw = $true }
  Assert ((-not $s3Threw) -and ($s3Val -ceq 'Shirube Global Auto Sync')) 'S3 broken JSON falls back without throwing'
  Set-Settings 'not json at all'
  Assert ((Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0') -ceq '32.0.0') 'S3 non-JSON text falls back'

  # S4: キー欠落・型不一致・空文字は既定値
  Set-Settings '{"taskNameGlobal":"OnlyThis","taskNameProject":"   ","rulesyncVersion":32}'
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'OnlyThis') 'S4 present string is used'
  Assert ((Get-ShirubeSetting -Name 'taskNameProject' -Default 'Shirube Project Auto Sync') -ceq 'Shirube Project Auto Sync') 'S4 blank string falls back'
  Assert ((Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0') -ceq '32.0.0') 'S4 number instead of string falls back'
  Set-Settings '{"rulesyncVersion":"9.9.9"}'
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'Shirube Global Auto Sync') 'S4 missing key falls back'
  Set-Settings '["a","b"]'
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'Shirube Global Auto Sync') 'S4 non-object JSON falls back'
  # ConvertFrom-Json unrolls a one-element array root into a usable-looking object.
  Set-Settings '[{"taskNameGlobal":"Other Task"}]'
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'Shirube Global Auto Sync') 'S4 single-element array root falls back'

  # S5: 既定値は現行値のまま (設定ファイル無しで評価)
  Remove-Item -LiteralPath $settingsPath -Force
  Assert ((Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') -ceq 'Shirube Global Auto Sync') 'S5 taskNameGlobal default is current value'
  Assert ((Get-ShirubeSetting -Name 'taskNameProject' -Default 'Shirube Project Auto Sync') -ceq 'Shirube Project Auto Sync') 'S5 taskNameProject default is current value'
  Assert ((Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0') -ceq '32.0.0') 'S5 rulesyncVersion default is current value'

  # S6: 直書きが設定参照に置き換わっていること (既定へ戻す変更の取りこぼし防止)
  foreach ($rel in @('Global-Management.ps1', 'Project-Management.ps1', 'Sync-GlobalRules.ps1', 'Sync-ProjectRules.ps1', 'Dashboard-Server.ps1')) {
    $txt = Get-Content -LiteralPath (Join-Path $devAuto $rel) -Raw
    Assert (-not $txt.Contains("'rulesync@32.0.0'")) ("S6 no hardcoded package: " + $rel)
  }
  $pmTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Project-Management.ps1') -Raw
  Assert (-not $pmTxt.Contains("Get-ScheduledTask -TaskName 'Shirube Project Auto Sync'")) 'S6 project task lookup goes through settings'
  $dsTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Dashboard-Server.ps1') -Raw
  Assert (-not $dsTxt.Contains("Set-MgmtProjectInterval 'Shirube Project Auto Sync'")) 'S6 dashboard interval uses settings task name'
}
finally {
  if (Test-Path -LiteralPath $scratch) {
    if (-not $scratch.StartsWith($testBase, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

if ($failures.Count -gt 0) {
  Write-Host ("FAILURES: " + ($failures -join ', '))
  exit 1
}
Write-Host 'ALL SETTINGS TESTS PASSED'
exit 0
