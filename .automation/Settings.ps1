# Settings.ps1 - 個人設定 (settings.json) の読み込み (dev source).
# settings.json は本ファイルと同じ階層。値は個人環境ごとに変えられる。
# ファイル欠落・JSON不正・キー欠落・型不一致はすべて Default へフォールバックし、
# 例外は投げない。Default は呼び出し側が現行値を渡す (既定では挙動不変)。
# 読むだけで書き込みはしない。秘密情報は扱わない。
# ErrorActionPreference は意図的に触らない (dot-source 先の好みを変えないため)。

function Get-ShirubeSettingsPath { return (Join-Path $PSScriptRoot 'settings.json') }

# 毎回読む (キャッシュなし)。settings.json は小さく、編集後の反映漏れを避ける。
function Read-ShirubeSettingsFile {
  $path = Get-ShirubeSettingsPath
  try {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $txt = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $txt) { return $null }
    $o = ConvertFrom-Json $txt
    # An array root (even one element) is not a settings object; ConvertFrom-Json
    # would otherwise unroll it into a usable-looking single object.
    if (($o -is [array]) -or ($o -isnot [System.Management.Automation.PSCustomObject])) { return $null }
    return $o
  }
  catch { return $null }
}

# name に対応する設定値。無効な値は Default。
function Get-ShirubeSetting {
  param([string]$Name = '', $Default = $null)
  if (-not $Name) { return $Default }
  $s = Read-ShirubeSettingsFile
  if ($null -eq $s) { return $Default }
  $pr = $null
  try { $pr = $s.PSObject.Properties[$Name] } catch { $pr = $null }
  if ($null -eq $pr) { return $Default }
  $v = $pr.Value
  if ($null -eq $v) { return $Default }
  if (($v -is [string]) -and ([string]$v).Trim() -eq '') { return $Default }
  # 型不一致 (数値/配列など) は既定へ。文字列キーだけを設定として受け付ける。
  if (($null -ne $Default) -and ($v.GetType() -ne $Default.GetType())) { return $Default }
  return $v
}
