# tests for /toggle - flip, speed vs state+command, double tap
#   .\test\toggle.ps1 -Base http://127.0.0.1:8787 -Secret dev-secret-change-me
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
    if ([string]$Actual -eq [string]$Expected) { Ok "$Label ($Expected)" } else { Bad "${Label}: expected [$Expected] got [$Actual]" }
}
function Get-Field {
    param([string]$Json, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
    try { $o = $Json | ConvertFrom-Json } catch { return '' }
    foreach ($key in $Path.Split('.')) { if ($null -eq $o) { return '' }; $o = $o.$key }
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
function Req {
    param([string]$Method, [string]$Path, $Body = $null)
    $a = @('-sS', '--max-time', '45', '-X', $Method, '-H', "X-Lock-Secret:$Secret")
    $tmp = $null
    if ($null -ne $Body) {
        $tmp = [System.IO.Path]::GetTempFileName()
        ($Body | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding ascii -NoNewline
        $a += @('-H', 'Content-Type:application/json', '-d', "@$tmp")
    }
    $a += @('-w', '\n%{http_code}', "$Base$Path")
    try { $r = Split-Response -Lines (& curl.exe @a) } finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    $script:Code = $r.Code; $script:Body = $r.Body
}
function Quote-Arg { param([string]$v) if ($v -match '[\s"]') { return '"' + ($v -replace '"','\"') + '"' }; return $v }
function Join-Args { param([string[]]$i) return (($i | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ') }
function Now-Ms { [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds }
function Start-Device {
    param([int]$ServoMs = 200)
    $script:DeviceProc = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $TmpDir 'dorm-lock-toggle-device.log') `
        -ArgumentList (Join-Args @('-NoProfile','-ExecutionPolicy','Bypass','-File',$DeviceScript,
                                   '-Base',$Base,'-Secret',$Secret,'-ServoMs',$ServoMs))
    Start-Sleep -Seconds 2
}
function Stop-Device {
    if ($script:DeviceProc) {
        & cmd.exe /c "taskkill /T /F /PID $($script:DeviceProc.Id) >nul 2>&1"
        $script:DeviceProc = $null; Start-Sleep -Seconds 1
    }
}

Write-Host "Target: $Base"
try {

Start-Device -ServoMs 200

Say '1. toggle flips the door and reports both ends'
Req GET '/state'
$before = Get-Field $script:Body 'state'
Write-Host "  starting from: $before"
if ($before -eq 'locked') { $expect = 'unlocked' } else { $expect = 'locked' }

Req POST '/toggle' @{}
Check 'toggle -> ok' (Get-Field $script:Body 'ok') 'true'
Check '  status' (Get-Field $script:Body 'status') 'confirmed'
Check '  reports where it came from' (Get-Field $script:Body 'from') $before
Check '  targeted the opposite' (Get-Field $script:Body 'target') $expect
Check '  door ended up there' (Get-Field $script:Body 'state') $expect

Req GET '/state'
Check '/state agrees' (Get-Field $script:Body 'state') $expect

Say '2. toggling again flips it back'
Req POST '/toggle' @{}
Check 'second toggle' (Get-Field $script:Body 'status') 'confirmed'
Check '  back to the original' (Get-Field $script:Body 'state') $before

Say '3. one round trip is genuinely faster than state+command'
Stop-Device
Start-Device -ServoMs 0

$t0 = Now-Ms
Req GET '/state'
$cur = Get-Field $script:Body 'state'
if ($cur -eq 'locked') { $opp = 'unlocked' } else { $opp = 'locked' }
Req POST '/command' @{ target = $opp }
$twoStep = (Now-Ms) - $t0

$t0 = Now-Ms
Req POST '/toggle' @{}
$oneStep = (Now-Ms) - $t0

Write-Host "  state+command: ${twoStep}ms"
Write-Host "  toggle:        ${oneStep}ms"
if ($oneStep -lt $twoStep) { $d = $twoStep - $oneStep; Ok "toggle is ${d}ms faster" }
else { Bad "toggle ($oneStep ms) was not faster than state+command ($twoStep ms)" }

Say '4. a double tap does NOT flip the door back'
Stop-Device
Req GET '/state'
$base2 = Get-Field $script:Body 'state'
if ($base2 -eq 'locked') { $opp2 = 'unlocked' } else { $opp2 = 'locked' }

# tap 1 waits with no device around, tap 2 comes in while its still pending
$aOut = Join-Path $TmpDir 'dorm-lock-tog-A.out'
$aTmp = [System.IO.Path]::GetTempFileName()
(@{ waitMs = 12000 } | ConvertTo-Json -Compress) | Set-Content -Path $aTmp -Encoding ascii -NoNewline
$aProc = Start-Process -FilePath 'curl.exe' -PassThru -NoNewWindow -RedirectStandardOutput $aOut `
    -ArgumentList (Join-Args @('-sS','--max-time','30','-X','POST','-H',"X-Lock-Secret:$Secret",
                               '-H','Content-Type:application/json','-d',"@$aTmp",
                               '-w','\n%{http_code}',"$Base/toggle"))
Start-Sleep -Seconds 1

Req GET '/state'
$pendingId = Get-Field $script:Body 'pending.commandId'
Check 'first tap is pending' (Get-Field $script:Body 'pending.target') $opp2

Req POST '/toggle' @{ waitMs = 1500 }
Check 'second tap joined the same command' (Get-Field $script:Body 'commandId') $pendingId
Check '  and did not issue a reversal' (Get-Field $script:Body 'target') $opp2
Check '  marked as joined' (Get-Field $script:Body 'joined') 'true'

$aProc | Wait-Process -Timeout 30
Remove-Item $aTmp -Force -ErrorAction SilentlyContinue

Start-Device -ServoMs 0
Start-Sleep -Seconds 3
Req GET '/state'
Check 'door moved exactly one step, not two' (Get-Field $script:Body 'state') $opp2

Say '5. /command still works unchanged'
Req POST '/command' @{ target = $base2 }
Check 'absolute command' (Get-Field $script:Body 'status') 'confirmed'
Check '  state' (Get-Field $script:Body 'state') $base2
Req POST '/command' @{ target = $base2 }
Check 'and is still idempotent' (Get-Field $script:Body 'status') 'already'

}
finally { Stop-Device }

Say 'result'
Write-Host "  $($script:Pass) passed, $($script:Fail) failed`n"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
