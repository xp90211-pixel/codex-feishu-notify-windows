[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testBase ('cfn-reliability-' + [guid]::NewGuid().ToString('N'))
$savedControl = $env:CFN_TEST_CONTROL
$children = New-Object System.Collections.Generic.List[object]
$count = 0
function Assert-Reliability {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Snapshot-Files {
    param([string] $Root)
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
        "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName).Hash)"
    }) -join [Environment]::NewLine)
}
function Start-Drain {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Process -Id $PID).Path
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-CfnNativeArgument (Join-Path $runtime 'drain.ps1'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    $children.Add($process)
    return $process
}
function Finish-Drain {
    param($Process)
    if (-not $Process.WaitForExit(20000)) { $Process.Kill(); throw 'Worker exceeded the test deadline.' }
    return $Process.ExitCode
}
function New-QueueItem {
    param([string] $Key, [string] $Kind = 'completed', [datetimeoffset] $CreatedAt = [datetimeoffset]::UtcNow)
    $id = Get-CfnEventId $Key
    $item = [pscustomobject]@{ schema = 2; event_id = $id; session_id = 'request-session'; kind = $Kind; created_at = $CreatedAt.ToString('o'); project = 'fixture'; task_preview = ''; result_preview = '' }
    Write-CfnJsonAtomic (Join-Path $runtime "spool\pending\$id.json") $item
    return $item
}
function Set-Mode {
    param([string] $Mode)
    [IO.File]::WriteAllText((Join-Path $control 'mode.txt'), $Mode)
}
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $runtime = Join-Path $testRoot '运行 目录'
    $control = Join-Path $testRoot 'control'
    Ensure-CfnDirectory $runtime
    Ensure-CfnDirectory $control
    $env:CFN_TEST_CONTROL = $control
    foreach ($name in @('CodexFeishuNotify.psm1', 'drain.ps1')) { Copy-Item -LiteralPath (Join-Path $projectRoot "src\$name") -Destination $runtime }
    $fixtureExe = Join-Path $testRoot '模拟 CLI.exe'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe "/out:$fixtureExe" (Join-Path $PSScriptRoot 'fixtures\FakeLarkCli.cs')
    if ($LASTEXITCODE) { throw 'Fixture compilation failed.' }
    $settingsPath = Join-Path $runtime 'settings.local.json'
    $raw = Get-Content (Join-Path $projectRoot 'config\settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $raw.delivery.holiday_region = 'None'
    $raw.delivery.all_day_weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    $raw.transport.require_profile = $false
    $raw.transport.chat_id = 'oc_TESTCONFIG1234'
    $raw.transport.cli_path = $fixtureExe
    $raw.transport.send_attempts_per_run = 1
    $raw.transport.retry_delay_seconds = 0
    $raw.desktop.enabled = $false
    Write-CfnJsonAtomic $settingsPath $raw
    $settings = Get-CfnSettings $runtime
    Assert-Reliability (-not $settings.IncludeTaskPreview -and -not $settings.IncludeResultPreview) 'New configurations must keep previews off.'
    $nl = [string][char]10
    $original = (@('# 中文路径', "model = 'sample'", '[features]', 'flag = true', '') -join $nl)
    $line = 'notify = ["pwsh", "C:\\中文 目录\\notify.ps1"]'
    $updated = Set-CfnNotifyLine $original $line
    $parsed = ConvertFrom-CfnToml $updated
    Assert-Reliability ($parsed.HasKey('notify') -and -not $parsed['features'].HasKey('notify')) 'notify landed inside a table.'
    Assert-Reliability ((Set-CfnNotifyLine $updated '') -ceq $original) 'Removing inserted notify changed unrelated TOML.'
    $multiline = (@('notify = [', "  'pwsh', # 注释", "  'C:\原目录\notify.ps1',", ']', '') -join $nl) + $original
    $replaced = Set-CfnNotifyLine $multiline $line
    Assert-Reliability ($replaced -ceq ($line + $nl + $original)) 'Multiline notify was not replaced as one span.'
    $invalidRejected = $false
    try { Set-CfnNotifyLine ('[features' + $nl + 'x=1') $line | Out-Null } catch { $invalidRejected = $true }
    Assert-Reliability $invalidRejected 'Malformed TOML must fail before mutation.'
    $tomlPath = Join-Path $testRoot 'config.toml'
    [IO.File]::WriteAllText($tomlPath, $original, (New-Object Text.UTF8Encoding($false)))
    Assert-Reliability ((Read-CfnUtf8File $tomlPath) -ceq $original) 'BOM-less UTF-8 text changed.'
    $secretJson = '{"nested":{"token":"fixture-private-token","app_secret":{"value":"hidden-value"}},"array":[{"password":"hidden-pass"}]}'
    Assert-Reliability ((Protect-CfnPreview $secretJson 1000) -notmatch 'fixture-private-token|hidden-value|hidden-pass') 'Nested JSON secrets leaked.'
    $statePath = Join-Path $testRoot 'desktop.json'
    Write-CfnJsonAtomic $statePath @{ 'thread-titles' = @{ 'id-1' = 'title' }; 'electron-persisted-atom-state' = @{ 'thread-reference-capability:id-1' = $false } }
    Assert-Reliability (-not (Test-CfnVisibleThread 'id-1' $statePath)) 'False capability must override stale titles.'
    Write-CfnJsonAtomic $statePath @{ unrelated = 'thread-reference-capability:id-1'; unknown = 'id-1' }
    Assert-Reliability (-not (Test-CfnVisibleThread 'id-1' $statePath)) 'Unknown state schema must fail closed.'
    foreach ($reply in @('', 'not json', '{}', 'null', '{"success":true}', '{"code":0}', '{"code":false,"data":{"message_id":"om_test"}}')) {
        Assert-Reliability (-not (Test-CfnTransportOutput 0 $reply).Success) "Unknown receipt was accepted: $reply"
    }
    Set-Mode 'success'
    $complex = '中文 空格 "引号" C:\dir with space\trail\ & %PATH%' + $nl + '第二行'
    $nativeArgs = @('--text', $complex, '--content', '{"text":"引号\"与反斜杠\\"}', '--empty', '')
    $transport = Invoke-CfnTransport $runtime $fixtureExe $nativeArgs $settings
    Assert-Reliability ((Test-CfnTransportOutput $transport.ExitCode $transport.Stdout).Success -and $transport.Stderr -match 'diagnostic') 'stdout/stderr separation or receipt failed.'
    $call = Get-ChildItem $control -Filter 'call-*.txt' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
    $actualArgs = @(Get-Content -LiteralPath $call.FullName -Encoding UTF8 | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
    Assert-Reliability (($actualArgs | ConvertTo-Json -Compress) -ceq ($nativeArgs | ConvertTo-Json -Compress)) 'Native argv quoting damaged Unicode, quotes, backslashes, or empty values.'
    $npmRoot = Join-Path $testRoot 'npm 空格'
    $npmBinary = Join-Path $npmRoot 'node_modules\@larksuite\cli\bin\lark-cli.exe'
    Ensure-CfnDirectory (Split-Path -Parent $npmBinary)
    Copy-Item -LiteralPath $fixtureExe -Destination $npmBinary
    $wrapper = Join-Path $npmRoot 'lark-cli.cmd'
    [IO.File]::WriteAllText($wrapper, '@node "%~dp0\node_modules\@larksuite\cli\bin\run.js" %*')
    Assert-Reliability ((Resolve-CfnNativeCli $wrapper) -ieq $npmBinary) 'npm wrapper resolution failed.'
    $transport = Invoke-CfnTransport $runtime $wrapper $nativeArgs $settings
    Assert-Reliability ((Test-CfnTransportOutput $transport.ExitCode $transport.Stdout).Success) 'npm wrapper native transport failed.'
    $queued = New-QueueItem 'uncertain'
    $expired = New-QueueItem 'expired' 'completed' ([datetimeoffset]::UtcNow.AddDays(-3))
    $before = Snapshot-Files $runtime
    $callsBefore = @(Get-ChildItem $control -Filter 'call-*.txt').Count
    $dryOutput = & (Join-Path $runtime 'drain.ps1') -DryRun
    Assert-Reliability ($LASTEXITCODE -eq 0 -and (Snapshot-Files $runtime) -ceq $before) 'DryRun mutated files or failed.'
    Assert-Reliability (@(Get-ChildItem $control -Filter 'call-*.txt').Count -eq $callsBefore) 'DryRun invoked the CLI.'
    Assert-Reliability (@($dryOutput | Where-Object State -eq 'expired').Count -eq 1) 'DryRun did not identify expired queue items.'
    foreach ($mode in @('empty', 'malformed', 'unknown', 'reject', 'exit')) {
        Set-Mode $mode
        Assert-Reliability ((Finish-Drain (Start-Drain)) -eq 2) "Unconfirmed $mode response must signal failure."
        Assert-Reliability (Test-Path (Join-Path $runtime "spool\pending\$($queued.event_id).json")) 'Unconfirmed delivery deleted its pending item.'
    }
    $raw.transport.timeout_seconds = 1
    Write-CfnJsonAtomic $settingsPath $raw
    Set-Mode 'hang'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Assert-Reliability ((Finish-Drain (Start-Drain)) -eq 2 -and $timer.Elapsed.TotalSeconds -lt 10) 'Transport timeout was not bounded.'
    Assert-Reliability (Test-Path (Join-Path $runtime "spool\pending\$($queued.event_id).json")) 'Timeout deleted its pending item.'
    $raw.transport.timeout_seconds = 30
    Write-CfnJsonAtomic $settingsPath $raw
    Set-Mode 'success'
    Assert-Reliability ((Finish-Drain (Start-Drain)) -eq 0) 'Confirmed delivery failed.'
    $receipt = Get-Content (Join-Path $runtime "spool\sent\$($queued.event_id).sent") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Reliability ($receipt.message_id -eq 'om_fixture' -and -not (Test-Path (Join-Path $runtime "spool\pending\$($queued.event_id).json"))) 'Receipt was not persisted before queue removal.'
    $first = New-QueueItem 'race-first'
    $second = New-QueueItem 'race-second'
    Set-Mode 'slow'
    $callsBefore = @(Get-ChildItem $control -Filter 'call-*.txt').Count
    $worker1 = Start-Drain
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while (@(Get-ChildItem $control -Filter 'call-*.txt').Count -eq $callsBefore -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert-Reliability (@(Get-ChildItem $control -Filter 'call-*.txt').Count -eq ($callsBefore + 1)) 'First worker never started.'
    $worker2 = Start-Drain
    Set-CfnDeliveryEnabled $runtime $false
    Assert-Reliability ((Finish-Drain $worker1) -eq 0 -and (Finish-Drain $worker2) -eq 0) 'Concurrent workers failed.'
    Assert-Reliability (@(Get-ChildItem $control -Filter 'call-*.txt').Count -eq ($callsBefore + 1)) 'Duplicate worker or post-disable submission occurred.'
    Assert-Reliability (@(Get-ChildItem (Join-Path $runtime 'spool\pending') -Filter '*.json').Count -eq 1) 'Disable should preserve the not-yet-submitted item.'
    Set-CfnDeliveryEnabled $runtime $true
    $identityA = Get-CfnRequestIdentity ([pscustomobject]@{ turn_id = 'turn'; tool_name = 'Bash'; tool_use_id = 'a'; tool_input = @{ command = 'a' } })
    $identityB = Get-CfnRequestIdentity ([pscustomobject]@{ turn_id = 'turn'; tool_name = 'Bash'; tool_use_id = 'b'; tool_input = @{ command = 'b' } })
    $idA = New-CfnPermissionEventId $runtime 'request-session' $identityA
    $idB = New-CfnPermissionEventId $runtime 'request-session' $identityB
    Set-CfnWaitingState $runtime 'request-session' $idA 'tagA' $identityA | Out-Null
    Set-CfnWaitingState $runtime 'request-session' $idB 'tagB' $identityB | Out-Null
    Assert-Reliability ($idA -ne $idB) 'Same-tool request IDs coalesced.'
    $unrelated = [pscustomobject]@{ turn_id = 'turn'; tool_name = 'Bash'; tool_use_id = 'other'; tool_input = @{ command = 'other' } }
    Resolve-CfnWaitingState $runtime 'request-session' 24 -ToolEvent $unrelated | Out-Null
    Assert-Reliability ((Test-Path (Join-Path $runtime "spool\state\waiting\$idA.json")) -and (Test-Path (Join-Path $runtime "spool\state\waiting\$idB.json"))) 'Unrelated tool use cleared a pending permission.'
    Resolve-CfnWaitingState $runtime 'request-session' 24 -ToolEvent ([pscustomobject]@{ turn_id = 'turn'; tool_name = 'Bash'; tool_use_id = 'a' }) | Out-Null
    Assert-Reliability (-not (Test-Path (Join-Path $runtime "spool\state\waiting\$idA.json")) -and (Test-Path (Join-Path $runtime "spool\state\waiting\$idB.json"))) 'Resolution did not target exactly one request.'
    Assert-Reliability (-not (New-CfnPermissionEventId $runtime 'request-session' $identityA)) 'Delayed permission resurrected an explicitly resolved request.'
    $noId = Get-CfnRequestIdentity ([pscustomobject]@{ turn_id = 'no-id'; tool_name = 'Bash'; tool_input = @{ command = 'same' } })
    $generation1 = New-CfnPermissionEventId $runtime 'request-session' $noId
    $generation2 = New-CfnPermissionEventId $runtime 'request-session' $noId
    Assert-Reliability ($generation1 -ne $generation2) 'No-ID fallback did not use distinct generations.'
    $permissionItem = [pscustomobject]@{ kind = 'needs-input'; event_id = $idB; thread_id = 'request-session'; project = 'fixture'; created_at = [datetimeoffset]::UtcNow.ToString('o') }
    Assert-Reliability (Test-CfnWaitingItemActive $runtime $permissionItem 24) 'An active permission item was rejected.'
    $textSettings = Get-CfnSettings $runtime
    $textSettings.MessageFormat = 'text'
    Assert-Reliability ((Get-CfnDeliveryPayload $permissionItem $textSettings).Content -match 'Codex') 'Permission text/Unicode emoji rendering failed.'
    Resolve-CfnWaitingState $runtime 'request-session' 24 -TurnId 'turn' | Out-Null
    Assert-Reliability (-not (Test-CfnWaitingItemActive $runtime $permissionItem 24)) 'Resolved permission remained sendable.'

    $today = [datetime]::Today
    $plan = @(Get-CfnSchedulePlan '18:40' '02:00' 1 @('Sunday') $null $today)
    $triggers = @(New-CfnScheduledTriggers $plan)
    $past = New-ScheduledTaskTrigger -Once -At $today.AddDays(-2).AddHours(3)
    $taskFixture = [pscustomobject]@{ Triggers = @($triggers + $past) }
    Assert-Reliability (Test-CfnScheduleTriggers $taskFixture $plan $today) 'A past holiday trigger caused a false mismatch.'
    $triggers[0].Repetition.Interval = 'PT2M'
    Assert-Reliability (-not (Test-CfnScheduleTriggers $taskFixture $plan $today)) 'Diagnostics missed a changed repetition interval.'

    $oldState = Join-Path $runtime 'spool\state\waiting\old.json'
    Write-CfnJsonAtomic $oldState @{ waiting_at = [datetimeoffset]::UtcNow.AddDays(-8).ToString('o') }
    (Get-Item $oldState).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-8)
    Invoke-CfnRetention $runtime (Get-CfnSettings $runtime)
    Assert-Reliability (-not (Test-Path $oldState)) 'Retention did not remove obsolete waiting state.'
    Write-Host "PASS: $count reliability assertions (offline transport, TOML, privacy, DryRun, concurrency, request identity)."
} finally {
    $env:CFN_TEST_CONTROL = $savedControl
    foreach ($child in $children) {
        if (-not $child.HasExited) { try { $child.Kill() } catch {} }
        $child.Dispose()
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ((Split-Path -Parent $resolved).TrimEnd('\') -eq $testBase -and (Split-Path -Leaf $resolved).StartsWith('cfn-reliability-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
