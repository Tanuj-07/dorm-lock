# fake esp32 (powershell). polls, sleeps like a servo would, confirms
#   .\test\device-sim.ps1 -Base https://dorm-lock.you.workers.dev -Secret abc123
# uses curl.exe not Invoke-WebRequest so it acts the same as the bash one
[CmdletBinding()]
param(
    [string]$Base = $(if ($env:BASE) { $env:BASE } else { 'http://127.0.0.1:8787' }),
    [string]$Secret = $env:SECRET,
    [int]$ServoMs = 400,
    [int]$FailEvery = 0,   # fail every Nth cmd, 0 = never
    [int]$MaxLoops = 0,
    [int]$StartAfter = -1  # -1 = ask /state
)

$ErrorActionPreference = 'Stop'
if (-not $Secret) { throw 'Set -Secret, or $env:SECRET before running.' }
$Base = $Base.TrimEnd('/')

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

# body, then the http code on the last line
function Split-Response {
    param([string[]]$Lines)
    $arr = @($Lines)
    if ($arr.Count -eq 0) { return @{ Code = '000'; Body = '' } }
    $code = [string]$arr[-1]
    if ($arr.Count -gt 1) { $body = ($arr[0..($arr.Count - 2)] -join "`n") } else { $body = '' }
    return @{ Code = $code; Body = $body }
}

function Invoke-Curl {
    param([string[]]$CurlArgs)
    $out = & curl.exe @CurlArgs
    return Split-Response -Lines $out
}

# temp file again because of the ps 5.1 quote thing
function Invoke-CurlJson {
    param([string]$Url, [hashtable]$Body)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        ($Body | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding ascii -NoNewline
        return Invoke-Curl @(
            '-sS', '--max-time', '45', '-X', 'POST',
            '-H', "X-Lock-Secret:$Secret",
            '-H', 'Content-Type:application/json',
            '-d', "@$tmp",
            '-w', '\n%{http_code}',
            $Url
        )
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# boot - get lastConfirmedId so we dont replay old stuff
$lastId = 0
if ($StartAfter -ge 0) {
    $lastId = $StartAfter
} else {
    $boot = Invoke-Curl @('-sS', '--max-time', '20', '-H', "X-Lock-Secret:$Secret", '-w', '\n%{http_code}', "$Base/state")
    if ($boot.Code -eq '200') {
        $bootId = Get-Field $boot.Body 'lastConfirmedId'
        if ($bootId -ne '') { $lastId = [int]$bootId }
        $bootState = Get-Field $boot.Body 'state'
        Write-Host "[device] boot: door is '$bootState', resuming after command id $lastId"
    } else {
        Write-Host "[device] boot: /state returned $($boot.Code); starting from 0" -ForegroundColor Yellow
    }
}

Write-Host "[device] polling $Base/poll (25s holds). Ctrl+C to stop."

$loops = 0
$executed = 0

while ($true) {
    $loops++
    if ($MaxLoops -gt 0 -and $loops -gt $MaxLoops) {
        Write-Host '[device] max loops reached'
        break
    }

    $r = Invoke-Curl @(
        '-sS', '--max-time', '40',
        '-H', "X-Lock-Secret:$Secret",
        '-w', '\n%{http_code}',
        "$Base/poll?after=$lastId"
    )

    if ($r.Code -eq '204') {
        Write-Host '[device] 204 no command, re-polling'
        continue
    }
    if ($r.Code -ne '200') {
        Write-Host "[device] poll failed http=$($r.Code) $($r.Body)" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        continue
    }

    $cmdId = Get-Field $r.Body 'commandId'
    $target = Get-Field $r.Body 'target'
    if ($cmdId -eq '') {
        Write-Host "[device] unparseable: $($r.Body)" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        continue
    }

    Write-Host "[device] command #$cmdId -> $target (moving servo ${ServoMs}ms)"
    Start-Sleep -Milliseconds $ServoMs

    $executed++
    $ok = $true
    if ($FailEvery -gt 0 -and ($executed % $FailEvery) -eq 0) {
        $ok = $false
        Write-Host "[device] simulating a servo failure on #$cmdId" -ForegroundColor Yellow
    }

    if ($ok) {
        $payload = @{ commandId = [int]$cmdId; ok = $true; state = $target }
    } else {
        $payload = @{ commandId = [int]$cmdId; ok = $false; detail = 'servo stalled' }
    }

    $c = Invoke-CurlJson -Url "$Base/confirm" -Body $payload
    Write-Host "[device] confirmed #$cmdId (http $($c.Code))"

    $lastId = [int]$cmdId
}
