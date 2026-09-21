Set-StrictMode -Version 2.0

function Get-CfnIdleOptions {
    param([string] $IntegrationRoot)
    $path = Join-Path $IntegrationRoot 'idle-reminder.settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $options = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $options.enabled) { return $null }
    if ($options.channel -ne 'feishu') { throw 'Invalid all-idle reminder channel.' }
    if ([int]$options.confirm_seconds -lt 1 -or [int]$options.confirm_seconds -gt 15) { throw 'Invalid all-idle confirmation interval.' }
    return $options
}

function Save-CfnIdleEndpoint {
    param([string] $IntegrationRoot)
    if ($null -eq (Get-CfnIdleOptions $IntegrationRoot)) { return }
    # Capture only the app-provided local endpoint, never credentials. Hooks
    # refresh it automatically after app restarts, even if a hook payload is bad.
    $pipe = [string]$env:CODEX_APP_TOOLS_PIPE_PATH
    $threadId = [string]$env:CODEX_THREAD_ID
    if ($pipe -notmatch '^\\\\\.\\pipe\\codex-browser-use-[A-Za-z0-9-]+$' -or
        $threadId -notmatch '^[0-9a-fA-F-]{36}$') { return }
    $path = Join-Path $IntegrationRoot 'spool\state\idle-app-endpoint.json'
    $lock = Enter-CfnMutex $IntegrationRoot 'idle-endpoint' 500
    if ($null -eq $lock) { return }
    try {
        if (Test-Path -LiteralPath $path) {
            try {
                $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($old.pipe -ceq $pipe -and $old.thread_id -ceq $threadId) { return }
            } catch { }
        }
        Write-CfnJsonAtomic $path @{ schema = 1; pipe = $pipe; thread_id = $threadId; captured_at = [datetimeoffset]::UtcNow.ToString('o') }
    } finally { Exit-CfnMutex $lock }
}

function Read-CfnIdlePipeBytes {
    param($Pipe, [int] $Count, [Diagnostics.Stopwatch] $Clock)
    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $remaining = 6000 - [int]$Clock.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'App status read timed out.' }
        $read = $Pipe.ReadAsync($buffer, $offset, $Count - $offset)
        if (-not $read.Wait($remaining)) { throw 'App status read timed out.' }
        $length = $read.GetAwaiter().GetResult()
        if ($length -le 0) { throw 'App status pipe closed.' }
        $offset += $length
    }
    return ,$buffer
}

function Invoke-CfnIdleStatusTool {
    param($Endpoint, [ValidateSet('list_threads', 'read_thread')] [string] $Tool, [hashtable] $Arguments)
    # This adapter uses the same local framed, read-only RPC as the bundled
    # codex-app-tools client. A separate app-server would not know the live tasks.
    $pipePath = [string]$Endpoint.pipe
    if ($pipePath -notmatch '^\\\\\.\\pipe\\codex-browser-use-[A-Za-z0-9-]+$') { throw 'Invalid app status endpoint.' }
    $pipeName = $pipePath.Substring('\\.\pipe\'.Length)
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(1000)
        $request = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = @{
            namespace = 'codex_app'; tool = $Tool; arguments = $Arguments
            threadId = [string]$Endpoint.thread_id
            callId = 'cfn-idle-' + [guid]::NewGuid().ToString('N')
            turnId = 'cfn-idle-status'
        } } | ConvertTo-Json -Depth 12 -Compress
        $payload = [Text.Encoding]::UTF8.GetBytes($request)
        $header = [BitConverter]::GetBytes([uint32]$payload.Length)
        $pipe.Write($header, 0, 4)
        $pipe.Write($payload, 0, $payload.Length)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $length = [BitConverter]::ToUInt32((Read-CfnIdlePipeBytes $pipe 4 $clock), 0)
        if ($length -le 0 -or $length -gt 8388608) { throw 'Invalid app status response length.' }
        $response = [Text.Encoding]::UTF8.GetString((Read-CfnIdlePipeBytes $pipe $length $clock)) | ConvertFrom-Json
        if ($null -ne (Get-CfnProperty $response 'error' $null)) { throw 'App status request failed.' }
        $result = $response.result
        if (-not $result.success) { throw 'App status tool returned an error.' }
        $texts = @($result.contentItems | Where-Object { $_.type -eq 'inputText' })
        if ($texts.Count -ne 1) { throw 'Unexpected app status result.' }
        return ($texts[0].text | ConvertFrom-Json)
    } finally { $pipe.Dispose() }
}

function ConvertTo-CfnIdleStatus {
    param($Status)
    $type = if ($Status -is [string]) { $Status } else { [string](Get-CfnProperty $Status 'type' '') }
    if ($type -in @('idle', 'notLoaded', 'systemError')) { return 'stopped' }
    if ($type -eq 'active') {
        if ($Status -is [string]) { return 'unknown' } # Need the live active flags.
        $flags = @(Get-CfnProperty $Status 'activeFlags' @())
        if (@($flags | Where-Object { $_ -notin @('waitingOnApproval', 'waitingOnUserInput') }).Count -gt 0) { return 'unknown' }
        if ($flags.Count -gt 0) { return 'waiting' }
        return 'running'
    }
    return 'unknown'
}

function Get-CfnIdleSnapshot {
    param([string] $IntegrationRoot)
    $endpointPath = Join-Path $IntegrationRoot 'spool\state\idle-app-endpoint.json'
    $endpoint = Get-Content -LiteralPath $endpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $app = Invoke-CfnIdleStatusTool $endpoint 'list_threads' @{ limit = 50 }
    if (@(Get-CfnProperty $app 'unavailableHosts' @()).Count -gt 0 -or
        @(Get-CfnProperty $app 'unavailableSources' @()).Count -gt 0) { throw 'App thread inventory is incomplete.' }
    $threads = @{}
    foreach ($thread in (@($app.pinnedThreads) + @($app.threads))) {
        if ($thread.kind -eq 'codex' -and $thread.hostId -eq 'local') { $threads[[string]$thread.id] = $thread.status }
    }
    # The UI list has a 50-item recency limit. Loaded task writer locks cover
    # older running local tasks as well, so the list limit cannot mean "idle".
    $lockRoot = Join-Path (Get-CfnCodexHome $IntegrationRoot) 'thread-writer-locks'
    if (-not (Test-Path -LiteralPath $lockRoot -PathType Container)) { throw 'Loaded task inventory is unavailable.' }
    $initialLocks = @(Get-ChildItem -LiteralPath $lockRoot -File -Filter '*.lock' -ErrorAction Stop |
        Where-Object { $_.BaseName -match '^[0-9a-fA-F-]{36}$' } | ForEach-Object BaseName)
    foreach ($threadId in $initialLocks) { $threads[$threadId] = 'readLive' }
    $running = 0; $waiting = 0; $stopped = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($threadId in @($threads.Keys)) {
        if ($clock.Elapsed.TotalSeconds -gt 20) { throw 'Task inventory scan exceeded its time budget.' }
        $status = $threads[$threadId]
        if ($status -eq 'active' -or $status -eq 'readLive') {
            $read = Invoke-CfnIdleStatusTool $endpoint 'read_thread' @{
                threadId = $threadId; hostId = 'local'; turnLimit = 1; includeOutputs = $false; maxOutputCharsPerItem = 1
            }
            $status = $read.thread.status
        }
        switch (ConvertTo-CfnIdleStatus $status) {
            'running' { $running++ }
            'waiting' { $waiting++ }
            'stopped' { $stopped++ }
            default { throw 'A task has an unknown runtime state.' }
        }
    }
    $finalLocks = @(Get-ChildItem -LiteralPath $lockRoot -File -Filter '*.lock' -ErrorAction Stop |
        Where-Object { $_.BaseName -match '^[0-9a-fA-F-]{36}$' } | ForEach-Object BaseName)
    if (@($finalLocks | Where-Object { $_ -notin $initialLocks }).Count -gt 0) { throw 'A task loaded during the status scan; retry later.' }
    return [pscustomobject]@{ Known = $true; Running = $running; Waiting = $waiting; Stopped = $stopped }
}

function Get-CfnIdleWindow {
    param($Settings, [datetime] $Now = (Get-Date))
    if (-not (Test-CfnScheduleActive $Settings $Now)) { return $null }
    if (Test-CfnAllDayDate $Settings $Now.Date) {
        $start = $Now.Date; $end = $start.AddDays(1)
    } else {
        $window = Get-CfnScheduleWindow $Settings.ScheduleStart $Settings.ScheduleEnd
        $start = $Now.Date.Add($window.StartTime)
        if ($start -gt $Now) { $start = $start.AddDays(-1) }
        $end = $start.Add($window.Duration)
    }
    return [pscustomobject]@{ Key = $start.ToString('yyyy-MM-ddTHH:mm:ss'); Start = $start; End = $end }
}

function Update-CfnIdleState {
    param($Previous, $Window, $Snapshot, [datetime] $Now, [int] $ConfirmSeconds = 5, [int] $GraceSeconds = 120)
    $state = $Previous
    if ($null -eq $state -or $state.window_key -cne $Window.Key) {
        $state = [pscustomobject]@{
            schema = 1; window_key = $Window.Key; window_end = $Window.End.ToString('o')
            phase = 'baseline'; initial_running = 0; idle_since = ''; notified_at = ''; retry_after = ''
        }
    }
    $notify = $false
    if ($state.phase -in @('notified', 'skipped')) { return [pscustomobject]@{ State = $state; Notify = $false } }
    if ($state.phase -eq 'baseline' -and ($Now - $Window.Start).TotalSeconds -gt $GraceSeconds) {
        $state.phase = 'skipped'
        return [pscustomobject]@{ State = $state; Notify = $false }
    }
    if (-not $Snapshot.Known) {
        $state.idle_since = ''
        return [pscustomobject]@{ State = $state; Notify = $false }
    }
    if ($state.phase -eq 'baseline') {
        # A late start or an unavailable app at the boundary does not prove a
        # task was running when the window opened. Do not fabricate that fact.
        if (($Now - $Window.Start).TotalSeconds -gt $GraceSeconds -or $Snapshot.Running -eq 0) {
            $state.phase = 'skipped'
        } else {
            $state.phase = 'armed'; $state.initial_running = $Snapshot.Running
        }
    } elseif ($state.phase -eq 'armed') {
        if ($Snapshot.Running -gt 0) { $state.idle_since = '' }
        elseif (-not $state.idle_since) { $state.idle_since = $Now.ToString('o') }
        else {
            $quietSeconds = ($Now - [datetime]::Parse($state.idle_since)).TotalSeconds
            $retryReady = -not $state.retry_after -or $Now -ge [datetime]::Parse($state.retry_after)
            $notify = $quietSeconds -ge $ConfirmSeconds -and $retryReady
        }
    }
    return [pscustomobject]@{ State = $state; Notify = $notify }
}

function Get-CfnIdleDeliveryPayload {
    param($Item, $Settings)
    $title = 'Codex 当前没有运行中的任务'
    $body = [string]$Item.result_preview
    if ($Settings.MessageFormat -eq 'card') {
        $card = New-CfnCardContent $Item $Settings | ConvertFrom-Json
        $card.header.title.content = $title
        $card.header.template = 'blue'
        $card.elements[0].text.content = $body
        return [pscustomobject]@{ MessageType = 'interactive'; ContentFlag = '--content'; Content = ($card | ConvertTo-Json -Depth 12 -Compress) }
    }
    return [pscustomobject]@{ MessageType = 'text'; ContentFlag = '--text'; Content = ($title + [Environment]::NewLine + $body) }
}

function Send-CfnIdleNotice {
    param([string] $IntegrationRoot, $Options, $Settings, $Window, $Snapshot, [datetime] $Now)
    $eventId = Get-CfnEventId ('all-idle|' + $Window.Key)
    $body = '{0:HH:mm}：本机 Codex 已没有继续运行中的任务；所有任务均已结束、停止，或正在等待你输入/授权。等待你介入：{1} 项。本时段只提醒一次。' -f $Now, $Snapshot.Waiting
    if ($Options.channel -eq 'feishu') {
        if (-not $Settings.FeishuEnabled) { return $false }
        $pending = Join-Path $IntegrationRoot "spool\pending\$eventId.json"
        $receipt = Join-Path $IntegrationRoot "spool\sent\$eventId.sent"
        if (-not (Test-Path -LiteralPath $pending) -and -not (Test-Path -LiteralPath $receipt)) {
            $item = @{ schema = 2; kind = 'all-idle'; event_id = $eventId
                thread_id = ''; turn_id = ''; created_at = [datetimeoffset]::UtcNow.ToString('o')
                project = 'Codex 全部本机任务'; task_preview = ''; result_preview = $body
                window_key = $Window.Key; window_end = $Window.End.ToString('o') }
            if (-not (Set-CfnQueueDeliveryWindow $IntegrationRoot $Settings $item)) { return $false }
            Write-CfnJsonAtomic $pending $item
        }
    }
    return $true
}

function Invoke-CfnIdleReminder {
    param([string] $IntegrationRoot, $Settings, $Control)
    $options = Get-CfnIdleOptions $IntegrationRoot
    if ($null -eq $options -or -not $Control.EffectiveActive -or -not $Control.ScheduledActive) { return }
    $window = Get-CfnIdleWindow $Settings
    if ($null -eq $window) { return }
    $lock = Enter-CfnMutex $IntegrationRoot 'idle-reminder' 0
    if ($null -eq $lock) { return }
    try {
        $path = Join-Path $IntegrationRoot 'spool\state\idle-window.json'
        $previous = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        if ($null -ne $previous -and $previous.window_key -ceq $window.Key -and $previous.phase -in @('notified','skipped')) { return }
        for ($check = 0; $check -lt 2; $check++) {
            try { $snapshot = Get-CfnIdleSnapshot $IntegrationRoot }
            catch { $snapshot = [pscustomobject]@{ Known = $false; Running = 0; Waiting = 0; Stopped = 0 } }
            $now = Get-Date
            if ($now -ge $window.End) { return }
            $updated = Update-CfnIdleState $previous $window $snapshot $now ([int]$options.confirm_seconds)
            Write-CfnJsonAtomic $path $updated.State
            if (-not $snapshot.Known) { Write-CfnLog $IntegrationRoot 'all_idle' 'status_unavailable'; return }
            if ($updated.Notify) {
                # Recheck the delivery switch after the live scans/quiet period.
                $currentSettings = Get-CfnSettings $IntegrationRoot
                $currentControl = Get-CfnDeliveryControlState $IntegrationRoot $currentSettings
                if (-not $currentControl.EffectiveActive -or -not $currentControl.ScheduledActive) { return }
                if (Send-CfnIdleNotice $IntegrationRoot $options $currentSettings $window $snapshot $now) {
                    $updated.State.phase = 'notified'; $updated.State.notified_at = $now.ToString('o')
                    Write-CfnLog $IntegrationRoot 'all_idle' 'queued' '' $options.channel
                } else {
                    $updated.State.retry_after = $now.AddMinutes(5).ToString('o')
                    Write-CfnLog $IntegrationRoot 'all_idle' 'delivery_unavailable'
                }
                Write-CfnJsonAtomic $path $updated.State
                return
            }
            if ($updated.State.phase -ne 'armed' -or $snapshot.Running -gt 0 -or $check -gt 0) { return }
            $previous = $updated.State
            Start-Sleep -Seconds ([int]$options.confirm_seconds)
        }
    } finally { Exit-CfnMutex $lock }
}

Export-ModuleMember -Function Get-CfnIdleOptions, Save-CfnIdleEndpoint, ConvertTo-CfnIdleStatus, Get-CfnIdleSnapshot, Get-CfnIdleWindow, Update-CfnIdleState, Get-CfnIdleDeliveryPayload, Invoke-CfnIdleReminder
