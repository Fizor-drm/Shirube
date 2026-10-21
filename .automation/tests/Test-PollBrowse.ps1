# Test-PollBrowse.ps1 - runtime checks for pollBrowse immediate + 450ms behavior.
# Extracts the real pollBrowse() from Dashboard-Server.ps1 and runs it under node
# with a fake api / clock / timer (no server start, no writes outside temp).
$ErrorActionPreference = 'Stop'
$initCwd = (Get-Location).Path
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot
$srvPath = Join-Path $devAuto 'Dashboard-Server.ps1'
$srvTxt = Get-Content -LiteralPath $srvPath -Raw

# static: key behaviors still present in source
Assert ($srvTxt.Contains('async function pollBrowse(browseId, deadline, myGen)')) 'pollBrowse defined'
Assert ($srvTxt.Contains('const wait = Math.min(450, rem);')) 'pollBrowse uses 450ms tail sleep'
Assert ($srvTxt.Contains('if(s && s.browseId === browseId')) 'pollBrowse stale-id guard checks browseId'
Assert ($srvTxt.Contains('if(browseCancel || myGen !== browseGen) return "cancelled";')) 'pollBrowse cancel/gen guard present'
Assert (-not $srvTxt.Contains('const wait = Math.min(1500, rem);')) 'pollBrowse no 1500ms initial sleep (immediate)'

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
Assert (($null -ne $nodeExe) -and ($nodeExe -ne '')) 'RUNTIME node available for pollBrowse harness'
if ($nodeExe) {
  $uijs = Join-Path ([System.IO.Path]::GetTempPath()) ('pollbrowse-' + [System.Guid]::NewGuid().ToString('N') + '.js')
  Set-Content -LiteralPath $uijs @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
var js = src.substring(src.indexOf('<script>') + 8, src.indexOf('</script>'));
function slice(a, b) { var i = js.indexOf(a); if (i < 0) throw new Error('slice miss: ' + a); var j = js.indexOf(b, i); if (j < 0) throw new Error('slice miss: ' + b); return js.substring(i, j); }
var POLLCODE = slice('async function pollBrowse', 'document.getElementById("btnBrowse")');

// fake state
var browseCancel = false;
var browseGen = 0;
var now = 0;
var apiCalls = [];
var apiImpl = function () { return null; };

global.Date = { now: function () { return now; } };
global.setTimeout = function (cb, ms) { now += (ms || 0); process.nextTick(cb); return 1; };
global.api = async function (path, method, body, timeout) {
  var n = apiCalls.length + 1;
  var call = { path: path, method: method, body: body, timeout: timeout, now: now, n: n };
  apiCalls.push(call);
  return await apiImpl(call, n);
};

eval(POLLCODE);

function reset() { browseCancel = false; browseGen = 0; now = 0; apiCalls = []; }

(async function () {
  // Scenario 1: immediate first poll, then retry after ~450ms, terminal on second
  reset();
  browseGen = 1;
  var seq = 0;
  apiImpl = function (call, n) {
    seq++;
    if (seq === 1) return { browseId: 'b1', status: 'pending' };
    return { browseId: 'b1', status: 'selected', path: '/tmp/x' };
  };
  var res1 = await pollBrowse('b1', now + 10000, 1);
  ok(res1 && res1.status === 'selected', 'S1 returns selected on second poll');
  ok(apiCalls.length === 2, 'S1 polled twice (initial + retry)');
  ok(apiCalls[0].now === 0, 'S1 first api is immediate (no initial sleep)');
  ok(apiCalls[1].now >= 450, 'S1 second api after ~450ms wait (got ' + (apiCalls[1] ? apiCalls[1].now : -1) + ')');

  // Scenario 2: stale browseId is ignored
  reset();
  browseGen = 1;
  seq = 0;
  apiImpl = function (call, n) {
    seq++;
    if (seq === 1) return { browseId: 'stale', status: 'selected' };
    return { browseId: 'b1', status: 'selected', path: '/tmp/y' };
  };
  var res2 = await pollBrowse('b1', now + 10000, 1);
  ok(res2 && res2.browseId === 'b1' && res2.status === 'selected', 'S2 stale id ignored, returns real selected');
  ok(apiCalls.length === 2, 'S2 stale first result triggers retry');

  // Scenario 3a: gen mismatch returns cancelled without calling api
  reset();
  browseGen = 2;
  apiImpl = function () { throw new Error('api should not be called'); };
  var res3a = await pollBrowse('b1', now + 10000, 1);
  ok(res3a === 'cancelled', 'S3a gen mismatch returns cancelled');
  ok(apiCalls.length === 0, 'S3a gen mismatch does not call api');

  // Scenario 3b: browseCancel during api returns cancelled
  reset();
  browseGen = 1;
  apiImpl = function (call, n) {
    browseCancel = true;
    return { browseId: 'b1', status: 'pending' };
  };
  var res3b = await pollBrowse('b1', now + 10000, 1);
  ok(res3b === 'cancelled', 'S3b browseCancel returns cancelled');

  // Scenario 4: small deadline returns timeout
  reset();
  browseGen = 1;
  apiImpl = function (call, n) { return { browseId: 'b1', status: 'pending' }; };
  var res4 = await pollBrowse('b1', now + 10, 1);
  ok(res4 === 'timeout', 'S4 small deadline returns timeout');
  ok(apiCalls.length >= 1, 'S4 calls api at least once before timeout');

  if (fails.length) { console.log('FAILED: ' + fails.length); process.exit(1); }
  console.log('ALL POLL-BROWSE CHECKS PASSED');
})();
'@ -Encoding ASCII
  try {
    & $nodeExe $uijs $srvPath
    Assert ($LASTEXITCODE -eq 0) 'RUNTIME pollBrowse harness passes (immediate/450/stale/cancel/deadline)'
  } finally {
    Remove-Item -LiteralPath $uijs -Force -ErrorAction SilentlyContinue
  }
}

Assert (((Get-Location).Path) -eq $initCwd) 'END cwd unchanged'
if ($failures.Count -eq 0) { Write-Host 'ALL POLL-BROWSE CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
