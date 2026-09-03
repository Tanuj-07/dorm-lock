# e2e test, powershell version of e2e.sh. this is the phone, device-sim.ps1 is the esp32
#   .\test\e2e.ps1 -Base https://dorm-lock.you.workers.dev -Secret abc123
# if it wont run: powershell -ExecutionPolicy Bypass -File test\e2e.ps1 -Secret ...
[CmdletBinding()]
param(
    [string]$Base = $(if ($env:BASE) { $env:BASE } else { 'http://127.0.0.1:8787' }),
    [string]$Secret = $env:SECRET
)

$ErrorActionPreference = 'Stop'
if (-not $Secret) { throw 'Set -Secret, or $env:SECRET before running.' }
$Base = $Base.TrimEnd('/')

$script:Pass = 0
$script:Fail = 0
# unique per run, the DO remembers requestIds
$RunId = 'e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$script:Body = ''
$script:Code = ''
$script:DeviceProc = $null

$DeviceScript = Join-Path $PSScriptRoot 'device-sim.ps1'
$TmpDir = $env:TEMP

function Say  { param([string]$m) Write-Host "`n== $m" -ForegroundColor White }
function Ok   { param([string]$m) $script:Pass++; Write-Host '  PASS ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Bad  { param([string]$m) $script:Fail++; Write-Host '  FAIL ' -ForegroundColor Red   -NoNewline; Write-Host $m }
function Check {
    param([string]$Label, $Actual, $Expected)
    if ([string]$Actual -eq [string]$Expected) { Ok "$Label ($Expected)" }
    else { Bad "${Label}: expected [$Expected] got [$Actual]" }
}

function Get-Field {
    param([string]$Json, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
    try { $o = $Json | ConvertFrom-Json } catch { return '' }
    foreach ($key in $Path.Split('.')) {
        if ($null -eq $o) { return '' }
        $o = $o.$key
    }
    if ($null -eq $o) { return '' }
    if ($o -is [bool]) { return $o.ToString().ToLower() }
    return [string]$o
}

function Split-Response {
    param([string[]]$Lines)
    $arr = @($Lines)
    if ($arr.Count -eq 0) { return @{ Code = '000'; Body = '' } }
    $code = [string]$arr[-1]
    if ($arr.Count -gt 1) { $body = ($arr[0..($arr.Count - 2)] -join "`n") } else { $body = '' }
    return @{ Code = $code; Body = $body }
}

# body can be a hashtable (-> json) or a raw string for the bad json test.
# goes thru a temp file bc ps 5.1 mangles quotes when you pass them to curl.exe
function Req {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [string]$Sec = $null,
        [switch]$NoAuth
    )
    if (-not $Sec) { $Sec = $Secret }
    # no space after the colon on purpose, see Join-Args
    $a = @('-sS', '--max-time', '45', '-X', $Method)
    if (-not $NoAuth) { $a += @('-H', "X-Lock-Secret:$Sec") }

    $tmp = $null
    if ($null -ne $Body) {
        $tmp = [System.IO.Path]::GetTempFileName()
        if ($Body -is [string]) { $text = $Body } else { $text = ($Body | ConvertTo-Json -Compress) }
        $text | Set-Content -Path $tmp -Encoding ascii -NoNewline
        $a += @('-H', 'Content-Type:application/json', '-d', "@$tmp")
    }
    $a += @('-w', '\n%{http_code}', "$Base$Path")

    try {
        $r = Split-Response -Lines (& curl.exe @a)
    } finally {
        if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    $script:Code = $r.Code
    $script:Body = $r.Body
}

# Start-Process doesnt quote args that have spaces. annoying
function Quote-Arg {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}
function Join-Args {
    param([string[]]$Items)
    return (($Items | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
}

function Start-Device {
    param([int]$ServoMs = 300)
    $log = Join-Path $TmpDir 'dorm-lock-device.log'
    $script:DeviceProc = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow `
        -RedirectStandardOutput $log `
        -ArgumentList (Join-Args @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $DeviceScript,
            '-Base', $Base, '-Secret', $Secret, '-ServoMs', $ServoMs
        ))
    Start-Sleep -Seconds 2
}

# curl.exe is slow to start on windows so the device takes a bit to re-park
function Wait-DeviceConnected {
    param([int]$TimeoutMs = 15000)
    $deadline = (Now-Ms) + $TimeoutMs
    while ((Now-Ms) -lt $deadline) {
        Req GET '/state'
        if ((Get-Field $script:Body 'device.connected') -eq 'true') { return 'true' }
        Start-Sleep -Milliseconds 250
    }
    return 'false'
}

function Wait-ForState {
    param([string]$Expected, [int]$TimeoutMs = 15000)
    $deadline = (Now-Ms) + $TimeoutMs
    while ((Now-Ms) -lt $deadline) {
        Req GET '/state'
        if ((Get-Field $script:Body 'state') -eq $Expected) { return $Expected }
        Start-Sleep -Milliseconds 400
    }
    return (Get-Field $script:Body 'state')
}

function Stop-Device {
    if ($script:DeviceProc) {
        # /T so the curl child dies too
        & cmd.exe /c "taskkill /T /F /PID $($script:DeviceProc.Id) >nul 2>&1"
        $script:DeviceProc = $null
        Start-Sleep -Seconds 1
    }
}

function Now-Ms { [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds }

Write-Host "Target: $Base"

try {

Say '1. auth'
$r = Split-Response -Lines (& curl.exe -sS -w '\n%{http_code}' "$Base/health")
Check 'GET /health needs no secret' $r.Code '200'

Req GET '/state' -NoAuth
Check 'GET /state without secret -> 401' $script:Code '401'

Req GET '/state' -Sec 'wrong'
Check 'GET /state with wrong secret -> 401' $script:Code '401'

Req GET "/state?secret=$Secret" -NoAuth
Check 'secret in the URL is not accepted -> 401' $script:Code '401'

Req GET '/state'
Check 'GET /state with secret -> 200' $script:Code '200'
Write-Host "  state=$(Get-Field $script:Body 'state') lastConfirmedId=$(Get-Field $script:Body 'lastConfirmedId')"

# ---- validation
Say '2. validation'
Req POST '/command' @{ target = 'banana' }
Check 'bad target -> 400' $script:Code '400'
Req POST '/command' @{}
Check 'missing target -> 400' $script:Code '400'
Req POST '/command' 'not json'
Check 'invalid json -> 400' $script:Code '400'
Req POST '/confirm' @{ ok = $true }
Check 'confirm without commandId -> 400' $script:Code '400'

Say '3. happy path (device online)'
Start-Device -ServoMs 300

Req POST '/command' @{ target = 'locked'; force = $true }
Check 'force lock -> ok' (Get-Field $script:Body 'ok') 'true'
Check '  status' (Get-Field $script:Body 'status') 'confirmed'
Check '  state'  (Get-Field $script:Body 'state')  'locked'
$baseId = [int](Get-Field $script:Body 'commandId')

Req POST '/command' @{ target = 'unlocked' }
Check 'unlock -> ok' (Get-Field $script:Body 'ok') 'true'
Check '  status' (Get-Field $script:Body 'status') 'confirmed'
Check '  state'  (Get-Field $script:Body 'state')  'unlocked'
Check '  command id incremented' (Get-Field $script:Body 'commandId') ($baseId + 1)
$unlockId = [int](Get-Field $script:Body 'commandId')

Req GET '/state'
Check '/state agrees' (Get-Field $script:Body 'state') 'unlocked'
Check '/state lastConfirmedId' (Get-Field $script:Body 'lastConfirmedId') $unlockId
Check '/state sees the device online' (Wait-DeviceConnected) 'true'

Say '4. idempotency'
Req POST '/command' @{ target = 'unlocked' }
Check 'repeat absolute target -> no new command' (Get-Field $script:Body 'status') 'already'
Check '  command id unchanged' (Get-Field $script:Body 'commandId') $unlockId

Req POST '/confirm' @{ commandId = $unlockId; ok = $true; state = 'unlocked' }
Check 'replayed confirm -> duplicate' (Get-Field $script:Body 'status') 'duplicate'
Check '  state unchanged' (Get-Field $script:Body 'state') 'unlocked'
Check '  lastConfirmedId unchanged' (Get-Field $script:Body 'lastConfirmedId') $unlockId

Req POST '/confirm' @{ commandId = ($unlockId + 99); ok = $true; state = 'locked' }
Check 'confirm for an id never issued -> 409' $script:Code '409'
Check '  error' (Get-Field $script:Body 'error') 'unknown_command'

Req GET '/state'
Check 'state survived the bogus confirms' (Get-Field $script:Body 'state') 'unlocked'

########## long poll
Say '5. long poll wakes immediately on a new command'
Stop-Device
Req GET '/state'
$after = [int](Get-Field $script:Body 'lastCommandId')

$pollOut = Join-Path $TmpDir 'dorm-lock-poll.out'
$t0 = Now-Ms
$pollProc = Start-Process -FilePath 'curl.exe' -PassThru -NoNewWindow `
    -RedirectStandardOutput $pollOut `
    -ArgumentList (Join-Args @('-sS', '--max-time', '30', '-H', "X-Lock-Secret:$Secret",
                    '-w', '\n%{http_code}', "$Base/poll?after=$after&wait=20000"))
Start-Sleep -Seconds 1

Req POST '/command' @{ target = 'locked'; waitMs = 0 }
$pollProc | Wait-Process -Timeout 30
$elapsed = (Now-Ms) - $t0

$pr = Split-Response -Lines (Get-Content $pollOut)
Check 'parked poll returned 200' $pr.Code '200'
Check '  it got the new command' (Get-Field $pr.Body 'target') 'locked'
$pendingId = [int](Get-Field $pr.Body 'commandId')
if ($elapsed -lt 5000) { Ok "poll woke in ${elapsed}ms (not after the 20s timeout)" }
else { Bad "poll took ${elapsed}ms - it timed out instead of being woken" }

Say '6. long poll returns 204 when nothing happens'
$t0 = Now-Ms
$r = Split-Response -Lines (& curl.exe -sS --max-time 20 -H "X-Lock-Secret:$Secret" -w '\n%{http_code}' "$Base/poll?after=$pendingId&wait=3000")
$elapsed = (Now-Ms) - $t0
Check 'no new command -> 204' $r.Code '204'
if ($elapsed -ge 2500) { Ok "held the connection open for ${elapsed}ms" }
else { Bad "returned after only ${elapsed}ms - it is not holding the request" }

Say '7. device offline'
Req POST '/confirm' @{ commandId = $pendingId; ok = $true; state = 'locked' }
Check 'manual confirm of the queued command' (Get-Field $script:Body 'status') 'confirmed'
Check '  state' (Get-Field $script:Body 'state') 'locked'

$t0 = Now-Ms
Req POST '/command' @{ target = 'unlocked'; waitMs = 3000; requestId = "$RunId-retry" }
$elapsed = (Now-Ms) - $t0
Check 'command with no device -> ok:false' (Get-Field $script:Body 'ok') 'false'
Check '  status' (Get-Field $script:Body 'status') 'timeout'
Check '  state is still the last confirmed one' (Get-Field $script:Body 'state') 'locked'
$stuckId = [int](Get-Field $script:Body 'commandId')
if ($elapsed -ge 2500 -and $elapsed -lt 8000) { Ok "waited ~${elapsed}ms then gave up" }
else { Bad "waited ${elapsed}ms, expected ~3000ms" }

Req POST '/command' @{ target = 'unlocked'; waitMs = 1000; requestId = "$RunId-retry" }
Check 'same requestId -> no second command issued' (Get-Field $script:Body 'commandId') $stuckId
Check '  marked as a replay' (Get-Field $script:Body 'replay') 'true'

Req GET '/state'
Check '  still exactly one command outstanding' (Get-Field $script:Body 'pending.commandId') $stuckId

Say '8. the device comes back and picks up the queued command'
Start-Device -ServoMs 300
Check 'queued unlock executed on reconnect' (Wait-ForState 'unlocked') 'unlocked'
Check '  nothing left pending' (Get-Field $script:Body 'pending') ''

Say '9. device reports a failure'
Stop-Device
Req POST '/command' @{ target = 'locked'; waitMs = 0 }
$failId = [int](Get-Field $script:Body 'commandId')
Req POST '/confirm' @{ commandId = $failId; ok = $false; detail = 'servo stalled' }
Check 'failed confirm -> ok:false' (Get-Field $script:Body 'ok') 'false'
Check '  status' (Get-Field $script:Body 'status') 'device_error'
Check '  state NOT advanced to the target' (Get-Field $script:Body 'state') 'unlocked'

Req GET '/state'
Check '  /state still unlocked' (Get-Field $script:Body 'state') 'unlocked'

# supersede
Say '10. a newer command supersedes the one still in flight'
Req GET '/state'
$startState = Get-Field $script:Body 'state'
if ($startState -eq 'locked') { $other = 'unlocked' } else { $other = 'locked' }

$aOut = Join-Path $TmpDir 'dorm-lock-A.out'
$aTmp = [System.IO.Path]::GetTempFileName()
(@{ target = $other; waitMs = 15000 } | ConvertTo-Json -Compress) | Set-Content -Path $aTmp -Encoding ascii -NoNewline
$aProc = Start-Process -FilePath 'curl.exe' -PassThru -NoNewWindow `
    -RedirectStandardOutput $aOut `
    -ArgumentList (Join-Args @('-sS', '--max-time', '30', '-X', 'POST',
                    '-H', "X-Lock-Secret:$Secret", '-H', 'Content-Type:application/json',
                    '-d', "@$aTmp", '-w', '\n%{http_code}', "$Base/command"))
Start-Sleep -Seconds 1

Req GET '/state'
$aId = [int](Get-Field $script:Body 'pending.commandId')
Check 'command A is pending' (Get-Field $script:Body 'pending.target') $other

Req POST '/command' @{ target = $startState; waitMs = 1500 }
$bId = [int](Get-Field $script:Body 'commandId')
Check 'command B got a new id' $bId ($aId + 1)

$aProc | Wait-Process -Timeout 30
Remove-Item $aTmp -Force -ErrorAction SilentlyContinue
$ar = Split-Response -Lines (Get-Content $aOut)
Check 'command A was released early, not left hanging' (Get-Field $ar.Body 'status') 'superseded'
Check '  A reports failure' (Get-Field $ar.Body 'ok') 'false'

Req GET "/poll?after=0&wait=0"
Check 'the device is handed B, never A' (Get-Field $script:Body 'commandId') $bId

Req POST '/confirm' @{ commandId = $bId; ok = $true; state = $startState }
Check 'confirm B' (Get-Field $script:Body 'status') 'confirmed'

}
finally {
    Stop-Device
}

Say 'result'
Write-Host "  $($script:Pass) passed, $($script:Fail) failed`n"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
