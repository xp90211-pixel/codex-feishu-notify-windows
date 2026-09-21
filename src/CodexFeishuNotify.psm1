Set-StrictMode -Version 2.0

function Get-CfnProperty {
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        $Default = $null
    )

    if ($null -ne $Object) {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Resolve-CfnPath {
    param([AllowEmptyString()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') { return $env:USERPROFILE }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        return Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    return $expanded
}

function Get-CfnCodexHome {
    param([string] $IntegrationRoot = '')
    if ($IntegrationRoot) {
        $manifestPath = Join-Path $IntegrationRoot 'install-state.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([IO.Path]::GetFullPath([string]$manifest.install_root) -ieq [IO.Path]::GetFullPath($IntegrationRoot)) {
                return Split-Path -Parent ([string]$manifest.config_path)
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath((Resolve-CfnPath $env:CODEX_HOME))
    }
    return Join-Path $env:USERPROFILE '.codex'
}

function Ensure-CfnDirectory {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-CfnLog {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $Stage,
        [Parameter(Mandatory = $true)] [string] $Status,
        [string] $EventId = '',
        [string] $Detail = ''
    )

    try {
        $logRoot = Join-Path $IntegrationRoot 'logs'
        Ensure-CfnDirectory $logRoot
        $safeDetail = Protect-CfnPreview $Detail 300
        $entry = [ordered]@{
            at = (Get-Date).ToUniversalTime().ToString('o')
            stage = $Stage
            status = $Status
            event_id = $EventId
            detail = $safeDetail
        }
        $path = Join-Path $logRoot 'notify.jsonl'
        $logLock = Enter-CfnMutex $IntegrationRoot 'log' 1000
        if ($null -eq $logLock) { return }
        try {
            if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 2097152) {
                for ($i = 3; $i -ge 1; $i--) {
                    $old = "$path.$i"
                    if (Test-Path -LiteralPath $old) {
                        if ($i -eq 3) { Remove-Item -LiteralPath $old -Force }
                        else { Move-Item -LiteralPath $old -Destination "$path.$($i + 1)" -Force }
                    }
                }
                Move-Item -LiteralPath $path -Destination "$path.1" -Force
            }
            Add-Content -LiteralPath $path -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
            if ($Stage -eq 'filter' -or $Status -match '(skipped|not_ready|missing|invalid)$') {
                Write-CfnJsonAtomic (Join-Path $IntegrationRoot 'spool\state\last-event.json') $entry
            }
        } finally { Exit-CfnMutex $logLock }
    } catch {
        # Notification logging is best-effort and must not break Codex.
    }
}

function Get-CfnSettings {
    param([Parameter(Mandatory = $true)] [string] $IntegrationRoot)

    $settingsPath = Join-Path $IntegrationRoot 'settings.local.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "Missing private settings file: $settingsPath"
    }

    $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $transport = Get-CfnProperty $raw 'transport' $null
    $filters = Get-CfnProperty $raw 'filters' $null
    $delivery = Get-CfnProperty $raw 'delivery' $null
    $message = Get-CfnProperty $raw 'message' $null
    $desktop = Get-CfnProperty $raw 'desktop' $null
    $lifecycle = Get-CfnProperty $raw 'lifecycle' $null
    $holidayCalendarSetting = [string](Get-CfnProperty $delivery 'holiday_calendar' 'holidays.local.json')
    $holidayCalendarPath = Resolve-CfnPath $holidayCalendarSetting
    if ($holidayCalendarPath -and -not [System.IO.Path]::IsPathRooted($holidayCalendarPath)) {
        $holidayCalendarPath = Join-Path $IntegrationRoot $holidayCalendarPath
    }
    $weekdayOrder = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    $rawAllDayWeekdays = @(Get-CfnProperty $delivery 'all_day_weekdays' @())
    $invalidAllDayWeekdays = @($rawAllDayWeekdays | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -notin $weekdayOrder })
    if ($invalidAllDayWeekdays.Count -gt 0) {
        throw "Invalid all-day weekday value(s): $($invalidAllDayWeekdays -join ', ')"
    }
    $allDayWeekdays = @($weekdayOrder | Where-Object { $rawAllDayWeekdays -contains $_ })

    $settings = [pscustomobject]@{
        Schema = [int](Get-CfnProperty $raw 'schema' 1)
        TransportType = [string](Get-CfnProperty $transport 'type' 'lark-cli')
        ChatId = [string](Get-CfnProperty $transport 'chat_id' '')
        LarkCliPath = Resolve-CfnPath ([string](Get-CfnProperty $transport 'cli_path' ''))
        LarkChannelHome = Resolve-CfnPath ([string](Get-CfnProperty $transport 'channel_home' '%USERPROFILE%\.lark-channel'))
        LarkChannelProfile = [string](Get-CfnProperty $transport 'profile' 'codex')
        RequireLarkProfile = [bool](Get-CfnProperty $transport 'require_profile' $true)
        FeishuEnabled = [bool](Get-CfnProperty $transport 'enabled' $true)
        SendAttemptsPerRun = [int](Get-CfnProperty $transport 'send_attempts_per_run' 2)
        RetryDelaySeconds = [int](Get-CfnProperty $transport 'retry_delay_seconds' 2)
        SendTimeoutSeconds = [int](Get-CfnProperty $transport 'timeout_seconds' 30)
        VisibleThreadsOnly = [bool](Get-CfnProperty $filters 'visible_threads_only' $true)
        SkipBridgeOrigin = [bool](Get-CfnProperty $filters 'skip_bridge_origin' $true)
        IncludeTaskPreview = [bool](Get-CfnProperty $message 'include_task_preview' $false)
        IncludeResultPreview = [bool](Get-CfnProperty $message 'include_result_preview' $false)
        IncludePermissionTool = [bool](Get-CfnProperty $message 'include_permission_tool' $false)
        MessageFormat = [string](Get-CfnProperty $message 'format' 'card')
        DesktopEnabled = [bool](Get-CfnProperty $desktop 'enabled' $true)
        DesktopOnlyWhenCodexBackground = [bool](Get-CfnProperty $desktop 'only_when_codex_background' $true)
        DesktopCompletion = [bool](Get-CfnProperty $desktop 'completion' $true)
        DesktopPermissionRequest = [bool](Get-CfnProperty $desktop 'permission_request' $true)
        StrictCompletionGate = [bool](Get-CfnProperty $lifecycle 'strict_completion_gate' $true)
        CompletionArmTtlMinutes = [int](Get-CfnProperty $lifecycle 'completion_arm_ttl_minutes' 10)
        NotifyPermissionRequests = [bool](Get-CfnProperty $lifecycle 'notify_permission_requests' $true)
        WaitingStateTtlHours = [int](Get-CfnProperty $lifecycle 'waiting_state_ttl_hours' 24)
        ReadyStateTtlHours = [int](Get-CfnProperty $lifecycle 'ready_state_ttl_hours' 720)
        ScheduleStart = [string](Get-CfnProperty $delivery 'start' '18:40')
        ScheduleEnabled = [bool](Get-CfnProperty $delivery 'enabled' $true)
        FreshNotificationsOnly = [bool](Get-CfnProperty $delivery 'fresh_notifications_only' $false)
        ScheduleEnd = [string](Get-CfnProperty $delivery 'end' '02:00')
        IntervalMinutes = [int](Get-CfnProperty $delivery 'interval_minutes' 1)
        HolidayRegion = [string](Get-CfnProperty $delivery 'holiday_region' 'None')
        HolidayCalendarPath = $holidayCalendarPath
        AllDayWeekdays = $allDayWeekdays
        MaxQueueAgeHours = [int](Get-CfnProperty $delivery 'max_queue_age_hours' 24)
        SentMarkerRetentionDays = [int](Get-CfnProperty $delivery 'sent_marker_retention_days' 90)
        ExpiredItemRetentionDays = [int](Get-CfnProperty $delivery 'expired_item_retention_days' 7)
        SuppressedItemRetentionDays = [int](Get-CfnProperty $delivery 'suppressed_item_retention_days' 7)
    }
    if ($settings.MessageFormat -notin @('text', 'card')) { throw 'Message format must be text or card.' }
    if ($settings.SendTimeoutSeconds -lt 1 -or $settings.SendTimeoutSeconds -gt 120) { throw 'Send timeout must be between 1 and 120 seconds.' }
    if ($settings.IntervalMinutes -lt 1 -or $settings.IntervalMinutes -gt 60) { throw 'Interval must be between 1 and 60 minutes.' }
    if ($settings.MaxQueueAgeHours -lt 1 -or $settings.MaxQueueAgeHours -gt 720) { throw 'Queue age must be between 1 and 720 hours.' }
    foreach ($retention in @($settings.SentMarkerRetentionDays, $settings.ExpiredItemRetentionDays, $settings.SuppressedItemRetentionDays)) {
        if ($retention -lt 1 -or $retention -gt 3650) { throw 'Retention must be between 1 and 3650 days.' }
    }
    if ($settings.SendAttemptsPerRun -lt 1 -or $settings.SendAttemptsPerRun -gt 5) { throw 'Send attempts per run must be between 1 and 5.' }
    if ($settings.RetryDelaySeconds -lt 0 -or $settings.RetryDelaySeconds -gt 30) { throw 'Retry delay must be between 0 and 30 seconds.' }
    if ($settings.CompletionArmTtlMinutes -lt 1 -or $settings.CompletionArmTtlMinutes -gt 60) { throw 'Completion arm TTL must be between 1 and 60 minutes.' }
    if ($settings.WaitingStateTtlHours -lt 1 -or $settings.WaitingStateTtlHours -gt 168) { throw 'Waiting-state TTL must be between 1 and 168 hours.' }
    if ($settings.ReadyStateTtlHours -lt 1 -or $settings.ReadyStateTtlHours -gt 8760) { throw 'Ready-state TTL must be between 1 and 8760 hours.' }
    return $settings
}

function ConvertTo-CfnIsoDuration {
    param([Parameter(Mandatory = $true)] [timespan] $Duration)

    if ($Duration.TotalSeconds -le 0) { throw 'Duration must be greater than zero.' }
    $days = [math]::Floor($Duration.TotalDays)
    $hours = $Duration.Hours
    $minutes = $Duration.Minutes
    $seconds = $Duration.Seconds
    $value = 'P'
    if ($days -gt 0) { $value += ('{0}D' -f $days) }
    if ($hours -gt 0 -or $minutes -gt 0 -or $seconds -gt 0) {
        $value += 'T'
        if ($hours -gt 0) { $value += ('{0}H' -f $hours) }
        if ($minutes -gt 0) { $value += ('{0}M' -f $minutes) }
        if ($seconds -gt 0) { $value += ('{0}S' -f $seconds) }
    }
    return $value
}

function Protect-CfnJsonValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $copy[$key] = if ([string]$key -match '^(?i:api[_-]?key|(?:access[_-]?|refresh[_-]?|auth[_-]?)?token|(?:app[_-]?|client[_-]?)?secret|password|passwd|webhook|authorization)$') { '[REDACTED]' }
                else { Protect-CfnJsonValue $Value[$key] }
        }
        return $copy
    }
    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        return Protect-CfnJsonValue $copy
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Protect-CfnJsonValue $_ }) }
    return $Value
}

function Protect-CfnPreview {
    param(
        [AllowEmptyString()] [string] $Text,
        [ValidateRange(1, 4000)] [int] $Limit
    )

    if ($null -eq $Text) { return '' }
    if ($Text.TrimStart().StartsWith('{') -or $Text.TrimStart().StartsWith('[')) {
        try { $Text = Protect-CfnJsonValue ($Text | ConvertFrom-Json -ErrorAction Stop) | ConvertTo-Json -Compress -Depth 50 } catch {}
    }
    $value = ($Text -replace '[\x00-\x1f]+', ' ' -replace '\s+', ' ').Trim()
    $value = $value -replace '(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [REDACTED]'
    $value = $value -replace '(?i)\bsk-[A-Za-z0-9_-]{12,}\b', 'sk-[REDACTED]'
    $sensitive = '(?:api[_-]?key|(?:access[_-]?|refresh[_-]?|auth[_-]?)?token|(?:app[_-]?|client[_-]?)?secret|password|passwd|webhook|authorization)'
    # JSON / quoted keys and quoted values (including escaped characters).
    $value = $value -replace ('(?i)(["'']?' + $sensitive + '["'']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|[^\s,;}]+)'), '$1"[REDACTED]"'
    $value = $value -replace '\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b', '[REDACTED_JWT]'
    if ($value.Length -gt $Limit) { return $value.Substring(0, $Limit) + '...' }
    return $value
}

function Test-CfnInternalPrompt {
    param([AllowEmptyString()] [string] $InputText)

    $patterns = @(
        '^\s*You write the one-line activity update displayed beneath an existing Codex task title\.',
        '^\s*You are a helpful assistant\. You will be presented with a user prompt, and your job is to provide a short title',
        '^\s*# Overview\s+Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex'
    )
    foreach ($pattern in $patterns) {
        if ($InputText -match $pattern) { return $true }
    }
    return $false
}

function Test-CfnVisibleThread {
    param(
        [AllowEmptyString()] [string] $ThreadId,
        [string] $StatePath = (Join-Path (Get-CfnCodexHome $PSScriptRoot) '.codex-global-state.json')
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) { return $false }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $false }
    try {
        $document = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $containers = @($document, (Get-CfnProperty $document 'electron-persisted-atom-state' $null))
        # An explicit denial anywhere wins over a stale title/cache entry.
        foreach ($container in $containers) {
            $capability = Get-CfnProperty $container ('thread-reference-capability:' + $ThreadId) $null
            if ($capability -is [bool] -and -not $capability) { return $false }
        }
        foreach ($container in $containers) {
            if ($null -eq $container) { continue }
            $capability = Get-CfnProperty $container ('thread-reference-capability:' + $ThreadId) $null
            if ($capability -is [bool]) { return $capability }
            foreach ($key in @('thread-titles', 'thread-title-cache')) {
                $titles = Get-CfnProperty $container $key $null
                if ($null -ne (Get-CfnProperty $titles $ThreadId $null)) { return $true }
                $byId = Get-CfnProperty $titles 'titles' $null
                if ($null -ne (Get-CfnProperty $byId $ThreadId $null)) { return $true }
            }
            foreach ($key in @('pinned-thread-ids', 'thread-order')) {
                if (@(Get-CfnProperty $container $key @()) -contains $ThreadId) { return $true }
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Get-CfnEventId {
    param([Parameter(Mandatory = $true)] [string] $Material)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Material))
        return (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 40)
    } finally {
        $sha.Dispose()
    }
}

function Write-CfnJsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    Ensure-CfnDirectory $parent
    $tempPath = '{0}.{1}.{2}.tmp' -f $Path, $PID, ([guid]::NewGuid().ToString('N'))
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tempPath, ($Value | ConvertTo-Json -Depth 50 -Compress), $utf8NoBom)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tempPath, $Path, [NullString]::Value) }
        else {
            try { [IO.File]::Move($tempPath, $Path) }
            catch { if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tempPath, $Path, [NullString]::Value) } else { throw } }
        }
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Move-CfnPendingToSuppressed {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [string] $Reason = 'feishu-disabled'
    )

    $pendingRoot = Join-Path $IntegrationRoot 'spool\pending'
    $suppressedRoot = Join-Path $IntegrationRoot 'spool\suppressed'
    $pendingItems = @(Get-ChildItem -LiteralPath $pendingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($pendingItems.Count -eq 0) {
        return [pscustomobject]@{ Count = 0; Path = $suppressedRoot }
    }

    Ensure-CfnDirectory $suppressedRoot
    $stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $movedCount = 0
    foreach ($file in $pendingItems) {
        $destinationName = '{0}-{1}' -f $stamp, $file.Name
        $destination = Join-Path $suppressedRoot $destinationName
        if (Test-Path -LiteralPath $destination) {
            $destination = Join-Path $suppressedRoot ('{0}-{1}-{2}' -f $stamp, [guid]::NewGuid().ToString('N'), $file.Name)
        }
        try {
            Move-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
            $movedCount++
        } catch {
            # A scheduled drain may have claimed this item just before the
            # switch changed. A missing source is a benign race; other errors
            # still fail loudly so the GUI does not report a false success.
            if (Test-Path -LiteralPath $file.FullName) { throw }
        }
    }
    Write-CfnLog $IntegrationRoot 'queue' 'suppressed' '' "reason=$Reason count=$movedCount"
    return [pscustomobject]@{ Count = $movedCount; Path = $suppressedRoot }
}

function Get-CfnStateFile {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [ValidateSet('completion', 'waiting', 'ready')] [string] $Category,
        [Parameter(Mandatory = $true)] [string] $SessionId
    )

    $key = Get-CfnEventId $SessionId
    return Join-Path (Join-Path $IntegrationRoot "spool\state\$Category") "$key.json"
}

function Set-CfnLifecycleReady {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $path = Get-CfnStateFile $IntegrationRoot 'ready' $SessionId
    Write-CfnJsonAtomic $path ([ordered]@{
        schema = 1
        session_id = $SessionId
        ready_at = [datetimeoffset]::UtcNow.ToString('o')
    })
    return $true
}

function Test-CfnLifecycleReady {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [ValidateRange(1, 8760)] [int] $TtlHours = 720
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $path = Get-CfnStateFile $IntegrationRoot 'ready' $SessionId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-CfnProperty $record 'session_id' '') -ne $SessionId) { return $false }
        $readyAt = [datetimeoffset]::Parse([string](Get-CfnProperty $record 'ready_at' ''))
        if ($readyAt -lt [datetimeoffset]::UtcNow.AddHours(-$TtlHours)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Set-CfnCompletionArm {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [AllowEmptyString()] [string] $TurnId = ''
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $path = Get-CfnStateFile $IntegrationRoot 'completion' $SessionId
    Write-CfnJsonAtomic $path ([ordered]@{
        schema = 1
        session_id = $SessionId
        turn_id = $TurnId
        armed_at = [datetimeoffset]::UtcNow.ToString('o')
    })
    return $true
}

function Use-CfnCompletionArm {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [AllowEmptyString()] [string] $TurnId = '',
        [ValidateRange(1, 60)] [int] $TtlMinutes = 10
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $path = Get-CfnStateFile $IntegrationRoot 'completion' $SessionId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-CfnProperty $record 'session_id' '') -ne $SessionId) { return $false }
        $recordTurn = [string](Get-CfnProperty $record 'turn_id' '')
        if ($TurnId -and $recordTurn -and $TurnId -ne $recordTurn) { return $false }
        $armedAt = [datetimeoffset]::Parse([string](Get-CfnProperty $record 'armed_at' ''))
        if ($armedAt -lt [datetimeoffset]::UtcNow.AddMinutes(-$TtlMinutes)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            return $false
        }
        $claim = "$path.claim-$PID-$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $path -Destination $claim -ErrorAction Stop
        Remove-Item -LiteralPath $claim -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Set-CfnWaitingState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [Parameter(Mandatory = $true)] [string] $EventId,
        [Parameter(Mandatory = $true)] [string] $ToastTag,
        $Identity = $null
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $path = Join-Path $IntegrationRoot "spool\state\waiting\$EventId.json"
    Write-CfnJsonAtomic $path ([ordered]@{
        schema = 2
        session_id = $SessionId
        event_id = $EventId
        toast_tag = $ToastTag
        request_id = [string](Get-CfnProperty $Identity 'RequestId' '')
        input_hash = [string](Get-CfnProperty $Identity 'InputHash' '')
        tool_name = [string](Get-CfnProperty $Identity 'ToolName' '')
        turn_id = [string](Get-CfnProperty $Identity 'TurnId' '')
        waiting_at = [datetimeoffset]::UtcNow.ToString('o')
    })
    return $true
}

function Resolve-CfnWaitingState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [ValidateRange(1, 168)] [int] $TtlHours = 24,
        $ToolEvent = $null,
        [string] $TurnId = ''
    )

    $result = [ordered]@{ Found = $false; EventId = ''; PendingRemoved = $false; ToastRemoved = $false; Stale = $false }
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return [pscustomobject]$result }
    $identity = if ($null -ne $ToolEvent) { Get-CfnRequestIdentity $ToolEvent } else { $null }
    if ($null -ne $identity -and $identity.RequestId) {
        $key = Get-CfnEventId ("request|$SessionId|$($identity.TurnId)|$($identity.RequestId)")
        Write-CfnJsonAtomic (Join-Path $IntegrationRoot "spool\state\resolved\$key.json") @{ resolved_at = [datetimeoffset]::UtcNow.ToString('o') }
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $IntegrationRoot 'spool\state\waiting') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string](Get-CfnProperty $record 'session_id' '') -cne $SessionId) { continue }
            if ($TurnId -and [string](Get-CfnProperty $record 'turn_id' '') -and $record.turn_id -cne $TurnId) { continue }
            if ($null -ne $identity) {
                if ([string](Get-CfnProperty $record 'turn_id' '') -cne $identity.TurnId -or
                    [string](Get-CfnProperty $record 'tool_name' '') -cne $identity.ToolName) { continue }
                $recordRequest = [string](Get-CfnProperty $record 'request_id' '')
                if ($recordRequest) {
                    if (-not $identity.RequestId -or $recordRequest -cne $identity.RequestId) { continue }
                } elseif (-not $identity.InputHash -or [string](Get-CfnProperty $record 'input_hash' '') -cne $identity.InputHash) { continue }
            }
            $candidates.Add([pscustomobject]@{ File = $file; Record = $record })
        } catch { Write-CfnLog $IntegrationRoot 'state' 'waiting_resolve_failed' '' $_.Exception.Message }
    }
    if ($null -ne $identity -and $candidates.Count -gt 1) { return [pscustomobject]$result }
    foreach ($candidate in $candidates) {
      try {
        $record = $candidate.Record
        $path = $candidate.File.FullName
        if ([string](Get-CfnProperty $record 'event_id' '') -notmatch '^[0-9a-f]{40}$') { continue }
        $result.Found = $true
        $result.EventId = [string](Get-CfnProperty $record 'event_id' '')
        $waitingAt = [datetimeoffset]::Parse([string](Get-CfnProperty $record 'waiting_at' ''))
        $result.Stale = ($waitingAt -lt [datetimeoffset]::UtcNow.AddHours(-$TtlHours))
        if ($result.EventId) {
            $pendingPath = Join-Path $IntegrationRoot "spool\pending\$($result.EventId).json"
            if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
                Remove-Item -LiteralPath $pendingPath -Force -ErrorAction Stop
                $result.PendingRemoved = $true
            }
        }
        $tag = [string](Get-CfnProperty $record 'toast_tag' '')
        if ($tag) { $result.ToastRemoved = [bool](Remove-CfnToast -Tag $tag) }
        if ([string](Get-CfnProperty $record 'request_id' '')) {
            Write-CfnJsonAtomic (Join-Path $IntegrationRoot "spool\state\resolved\$($result.EventId).json") @{ resolved_at = [datetimeoffset]::UtcNow.ToString('o') }
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
      } catch {
        Write-CfnLog $IntegrationRoot 'state' 'waiting_resolve_failed' '' $_.Exception.Message
      }
    }
    return [pscustomobject]$result
}

function Test-CfnCodexForeground {
    param([string[]] $ProcessNames = @('Codex', 'ChatGPT'))

    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        if (-not ('CfnForegroundWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CfnForegroundWindow {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
        }
        $handle = [CfnForegroundWindow]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) { return $false }
        [uint32]$processId = 0
        [void][CfnForegroundWindow]::GetWindowThreadProcessId($handle, [ref]$processId)
        if ($processId -eq 0) { return $false }
        $process = Get-Process -Id $processId -ErrorAction Stop
        return @($ProcessNames | Where-Object { $_ -ieq $process.ProcessName }).Count -gt 0
    } catch {
        return $false
    }
}

function New-CfnToastXml {
    param(
        [Parameter(Mandatory = $true)] [string] $Title,
        [Parameter(Mandatory = $true)] [string] $Body,
        [switch] $Persistent
    )

    $safeTitle = [System.Security.SecurityElement]::Escape((Protect-CfnPreview $Title 120))
    $safeBody = [System.Security.SecurityElement]::Escape((Protect-CfnPreview $Body 500))
    $attributes = if ($Persistent) { ' scenario="reminder"' } else { ' duration="long"' }
    $actions = if ($Persistent) { '<actions><action activationType="system" arguments="dismiss" content="Dismiss"/></actions>' } else { '' }
    return '<toast{0}><visual><binding template="ToastGeneric"><text>{1}</text><text>{2}</text></binding></visual>{3}</toast>' -f $attributes, $safeTitle, $safeBody, $actions
}

function Show-CfnToast {
    param(
        [Parameter(Mandatory = $true)] [string] $Title,
        [Parameter(Mandatory = $true)] [string] $Body,
        [AllowEmptyString()] [string] $Tag = '',
        [switch] $Persistent
    )

    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml((New-CfnToastXml -Title $Title -Body $Body -Persistent:$Persistent))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        if ($Tag) {
            $toast.Tag = (Protect-CfnPreview $Tag 64)
            $toast.Group = 'codex-feishu-notify'
        }
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    } catch {
        return $false
    }
}

function Remove-CfnToast {
    param([Parameter(Mandatory = $true)] [string] $Tag)

    if ($env:OS -ne 'Windows_NT' -or [string]::IsNullOrWhiteSpace($Tag)) { return $false }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove(
            (Protect-CfnPreview $Tag 64),
            'codex-feishu-notify',
            $appId
        )
        return $true
    } catch {
        return $false
    }
}

function Show-CfnDesktopEvent {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] $Settings,
        [Parameter(Mandatory = $true)] [ValidateSet('completed', 'needs-input')] [string] $Kind,
        [Parameter(Mandatory = $true)] [string] $Body,
        [AllowEmptyString()] [string] $Tag = ''
    )

    if (-not $Settings.DesktopEnabled) { return $false }
    if ($Kind -eq 'completed' -and -not $Settings.DesktopCompletion) { return $false }
    if ($Kind -eq 'needs-input' -and -not $Settings.DesktopPermissionRequest) { return $false }
    if ($Settings.DesktopOnlyWhenCodexBackground -and (Test-CfnCodexForeground)) {
        Write-CfnLog $IntegrationRoot 'desktop' 'foreground_suppressed' '' $Kind
        return $false
    }
    $title = if ($Kind -eq 'completed') { 'Codex 任务完成' } else { 'Codex 等待授权' }
    $shown = Show-CfnToast -Title $title -Body $Body -Tag $Tag -Persistent:($Kind -eq 'needs-input')
    Write-CfnLog $IntegrationRoot 'desktop' $(if ($shown) { 'shown' } else { 'show_failed' }) '' $Kind
    return $shown
}

function Get-CfnScheduleWindow {
    param(
        [Parameter(Mandatory = $true)] [string] $Start,
        [Parameter(Mandatory = $true)] [string] $End
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        $startDate = [datetime]::ParseExact($Start, 'HH:mm', $culture)
        $endDate = [datetime]::ParseExact($End, 'HH:mm', $culture)
    } catch {
        throw 'Delivery start/end must use 24-hour HH:mm format.'
    }

    $duration = $endDate.TimeOfDay - $startDate.TimeOfDay
    if ($duration.TotalMinutes -le 0) { $duration = $duration.Add([timespan]::FromDays(1)) }
    if ($duration.TotalMinutes -le 0 -or $duration.TotalMinutes -gt 1440) {
        throw 'Delivery window must be longer than zero and no longer than 24 hours.'
    }

    [pscustomobject]@{
        StartTime = $startDate.TimeOfDay
        EndTime = $endDate.TimeOfDay
        Duration = $duration
        IsoDuration = ConvertTo-CfnIsoDuration $duration
    }
}

function Get-CfnHolidayCalendar {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Holiday calendar was not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $region = [string](Get-CfnProperty $raw 'region' '')
    if (-not $region) { throw 'Holiday calendar region is missing.' }
    $entries = @(Get-CfnProperty $raw 'holidays' @())
    $normalized = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($entry in $entries) {
        $dateText = [string](Get-CfnProperty $entry 'date' '')
        if (-not $dateText) { throw 'Holiday entry is missing a date.' }
        try {
            $date = [datetime]::ParseExact($dateText, 'yyyy-MM-dd', $culture).Date
        } catch {
            throw "Invalid holiday date '$dateText'; expected yyyy-MM-dd."
        }
        if ($seen.ContainsKey($dateText)) { throw "Duplicate holiday date: $dateText" }
        $seen[$dateText] = $true
        $normalized.Add([pscustomobject]@{
            Date = $date
            DateText = $dateText
            Name = [string](Get-CfnProperty $entry 'name' 'Public holiday')
            Observed = [bool](Get-CfnProperty $entry 'observed' $false)
        })
    }
    if ($normalized.Count -eq 0) { throw 'Holiday calendar contains no holiday dates.' }

    [pscustomobject]@{
        Schema = [int](Get-CfnProperty $raw 'schema' 1)
        Region = $region
        TimeZone = [string](Get-CfnProperty $raw 'timezone' '')
        SourceUrl = [string](Get-CfnProperty (Get-CfnProperty $raw 'source' $null) 'url' '')
        Holidays = @($normalized | Sort-Object Date)
        Workdays = @(Get-CfnProperty $raw 'workdays' @())
    }
}

function Get-CfnHolidayGapWindows {
    param(
        [Parameter(Mandatory = $true)] [datetime] $HolidayDate,
        [Parameter(Mandatory = $true)] [string] $ScheduleStart,
        [Parameter(Mandatory = $true)] [string] $ScheduleEnd
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $start = [datetime]::ParseExact($ScheduleStart, 'HH:mm', $culture).TimeOfDay
    $end = [datetime]::ParseExact($ScheduleEnd, 'HH:mm', $culture).TimeOfDay
    if ($start -eq $end) { return @() }

    $day = $HolidayDate.Date
    $gaps = New-Object System.Collections.Generic.List[object]
    if ($end -lt $start) {
        $gapStart = $day.Add($end)
        $gapEnd = $day.Add($start)
        $duration = $gapEnd - $gapStart
        $gaps.Add([pscustomobject]@{
            Start = $gapStart
            End = $gapEnd
            Duration = $duration
            IsoDuration = ConvertTo-CfnIsoDuration $duration
        })
    } else {
        if ($start.TotalMinutes -gt 0) {
            $gapStart = $day
            $gapEnd = $day.Add($start)
            $duration = $gapEnd - $gapStart
            $gaps.Add([pscustomobject]@{
                Start = $gapStart
                End = $gapEnd
                Duration = $duration
                IsoDuration = ConvertTo-CfnIsoDuration $duration
            })
        }
        if ($end.TotalMinutes -lt 1440) {
            $gapStart = $day.Add($end)
            $gapEnd = $day.AddDays(1)
            $duration = $gapEnd - $gapStart
            $gaps.Add([pscustomobject]@{
                Start = $gapStart
                End = $gapEnd
                Duration = $duration
                IsoDuration = ConvertTo-CfnIsoDuration $duration
            })
        }
    }
    return $gaps.ToArray()
}

function Get-CfnManualDeliveryStatePath {
    param([Parameter(Mandatory = $true)] [string] $IntegrationRoot)

    return Join-Path $IntegrationRoot 'spool\state\manual-delivery.json'
}

function Clear-CfnManualDeliveryState {
    param([Parameter(Mandatory = $true)] [string] $IntegrationRoot)

    $stateLock = Enter-CfnMutex $IntegrationRoot 'state'
    try {
        $path = Get-CfnManualDeliveryStatePath $IntegrationRoot
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    } finally { Exit-CfnMutex $stateLock }
}

function Set-CfnManualDeliveryState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [ValidateSet('force', 'pause')] [string] $Mode,
        [Parameter(Mandatory = $true)] [datetimeoffset] $ExpiresAt,
        [datetimeoffset] $Now = [datetimeoffset]::Now
    )

    if ($ExpiresAt -le $Now) { throw 'Manual delivery override must expire in the future.' }
    $stateLock = Enter-CfnMutex $IntegrationRoot 'state'
    try {
    $path = Get-CfnManualDeliveryStatePath $IntegrationRoot
    Write-CfnJsonAtomic $path ([ordered]@{
        schema = 1
        mode = $Mode
        created_at = $Now.ToUniversalTime().ToString('o')
        expires_at = $ExpiresAt.ToUniversalTime().ToString('o')
    })
    return Get-CfnManualDeliveryState $IntegrationRoot -Now $Now
    } finally { Exit-CfnMutex $stateLock }
}

function Get-CfnManualDeliveryState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [datetimeoffset] $Now = [datetimeoffset]::Now
    )

    $path = Get-CfnManualDeliveryStatePath $IntegrationRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $mode = [string](Get-CfnProperty $record 'mode' '')
        if ($mode -notin @('force', 'pause')) { throw 'Unknown manual delivery mode.' }
        $expiresAt = [datetimeoffset]::Parse([string](Get-CfnProperty $record 'expires_at' '')).ToUniversalTime()
        if ($expiresAt -le $Now.ToUniversalTime()) {
            return $null
        }
        return [pscustomobject]@{
            Mode = $mode
            CreatedAt = [datetimeoffset]::Parse([string](Get-CfnProperty $record 'created_at' '')).ToUniversalTime()
            ExpiresAt = $expiresAt
            Path = $path
        }
    } catch {
        throw 'Invalid manual delivery state; repair or clear it in the settings UI.'
    }
}

function Test-CfnAllDayDate {
    param(
        [Parameter(Mandatory = $true)] $Settings,
        [Parameter(Mandatory = $true)] [datetime] $Date
    )

    $dateOnly = $Date.Date
    if (@($Settings.AllDayWeekdays) -contains $dateOnly.DayOfWeek.ToString()) { return $true }
    if ([string]$Settings.HolidayRegion -eq 'None' -or
        [string]::IsNullOrWhiteSpace([string]$Settings.HolidayCalendarPath) -or
        -not (Test-Path -LiteralPath $Settings.HolidayCalendarPath -PathType Leaf)) {
        return $false
    }
    try {
        $calendar = Get-CfnHolidayCalendar $Settings.HolidayCalendarPath
        return [bool](@($calendar.Holidays | Where-Object { $_.Date -eq $dateOnly }).Count -gt 0)
    } catch {
        # The daily window remains usable if an optional calendar is missing or
        # damaged. The configuration checker reports the calendar error.
        return $false
    }
}

function Test-CfnScheduleActive {
    param(
        [Parameter(Mandatory = $true)] $Settings,
        [datetime] $Now = (Get-Date)
    )

    if (Test-CfnAllDayDate $Settings $Now.Date) { return $true }
    $window = Get-CfnScheduleWindow $Settings.ScheduleStart $Settings.ScheduleEnd
    if ($window.Duration.TotalMinutes -ge 1440) { return $true }
    $time = $Now.TimeOfDay
    if ($window.EndTime -gt $window.StartTime) {
        return ($time -ge $window.StartTime -and $time -lt $window.EndTime)
    }
    return ($time -ge $window.StartTime -or $time -lt $window.EndTime)
}

function Get-CfnNextScheduleStart {
    param(
        [Parameter(Mandatory = $true)] $Settings,
        [datetime] $Now = (Get-Date)
    )

    $window = Get-CfnScheduleWindow $Settings.ScheduleStart $Settings.ScheduleEnd
    $candidates = New-Object System.Collections.Generic.List[datetime]
    # A daily start always occurs by tomorrow. One additional day keeps this
    # robust around exact boundaries and custom all-day extensions.
    foreach ($offset in 0..2) {
        $date = $Now.Date.AddDays($offset)
        $dailyStart = $date.Add($window.StartTime)
        if ($dailyStart -gt $Now) { $candidates.Add($dailyStart) }
        if (Test-CfnAllDayDate $Settings $date) {
            foreach ($gap in @(Get-CfnHolidayGapWindows $date $Settings.ScheduleStart $Settings.ScheduleEnd)) {
                if ($gap.Start -gt $Now) { $candidates.Add([datetime]$gap.Start) }
            }
        }
    }
    $next = @($candidates | Sort-Object | Select-Object -First 1)
    if ($next.Count -eq 0) { throw 'The next scheduled delivery start could not be calculated.' }
    return [datetime]$next[0]
}

function Get-CfnDeliveryControlState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] $Settings,
        [datetime] $Now = (Get-Date)
    )

    $manual = Get-CfnManualDeliveryState $IntegrationRoot -Now ([datetimeoffset]$Now)
    $scheduled = Test-CfnScheduleActive $Settings $Now
    $mode = if ($null -ne $manual) { [string]$manual.Mode } else { '' }
    $effective = if ($mode -eq 'pause') { $false } elseif ($mode -eq 'force') { $true } else { $scheduled }
    $reason = if ($mode -eq 'pause') {
        'manual_pause'
    } elseif ($mode -eq 'force') {
        'manual_force'
    } elseif ($scheduled) {
        'schedule'
    } else {
        'outside_schedule'
    }
    $enabled = [bool](Get-CfnProperty $Settings 'ScheduleEnabled' $true)
    $controlPath = Join-Path $IntegrationRoot 'spool\state\runtime-control.json'
    if (Test-Path -LiteralPath $controlPath -PathType Leaf) {
        $runtime = Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $enabled = $enabled -and [bool](Get-CfnProperty $runtime 'enabled' $false)
    }
    if (-not $enabled) { $effective = $false; $reason = 'schedule_disabled' }
    return [pscustomobject]@{
        ScheduledActive = [bool]$scheduled
        EffectiveActive = [bool]$effective
        Reason = $reason
        ManualMode = $mode
        ManualExpiresAt = if ($null -ne $manual) { $manual.ExpiresAt } else { $null }
        NextScheduleStart = Get-CfnNextScheduleStart $Settings $Now
    }
}

function Get-CfnFreshDeliveryWindow {
    param([string] $IntegrationRoot, $Settings, [datetime] $Now = (Get-Date))
    $control = Get-CfnDeliveryControlState $IntegrationRoot $Settings $Now
    if (-not $Settings.FeishuEnabled -or -not $control.EffectiveActive) { return $null }
    $manual = Get-CfnManualDeliveryState $IntegrationRoot -Now ([datetimeoffset]$Now)
    if ($null -ne $manual -and $manual.Mode -eq 'force') {
        return [pscustomobject]@{ Start = $manual.CreatedAt; End = $manual.ExpiresAt }
    }
    if (Test-CfnAllDayDate $Settings $Now.Date) {
        $start = $Now.Date; $end = $start.AddDays(1)
    } else {
        $window = Get-CfnScheduleWindow $Settings.ScheduleStart $Settings.ScheduleEnd
        $start = $Now.Date.Add($window.StartTime)
        if ($start -gt $Now) { $start = $start.AddDays(-1) }
        $end = $start.Add($window.Duration)
    }
    return [pscustomobject]@{ Start = [datetimeoffset]$start; End = [datetimeoffset]$end }
}

function Set-CfnQueueDeliveryWindow {
    param([string] $IntegrationRoot, $Settings, $QueueItem, [datetime] $Now = (Get-Date))
    if (-not [bool](Get-CfnProperty $Settings 'FreshNotificationsOnly' $false)) { return $true }
    $window = Get-CfnFreshDeliveryWindow $IntegrationRoot $Settings $Now
    if ($null -eq $window) { return $false }
    $created = [datetimeoffset]::Parse([string]$QueueItem.created_at)
    if ($created -lt $window.Start -or $created -ge $window.End -or $created -gt [datetimeoffset]$Now) { return $false }
    $fields = @{
        delivery_window_start = $window.Start.ToUniversalTime().ToString('o')
        delivery_window_end = $window.End.ToUniversalTime().ToString('o')
    }
    foreach ($name in $fields.Keys) {
        if ($QueueItem -is [Collections.IDictionary]) { $QueueItem[$name] = $fields[$name] }
        else { $QueueItem | Add-Member NoteProperty $name $fields[$name] -Force }
    }
    return $true
}

function Get-CfnFreshActivityPath {
    param([string] $IntegrationRoot, [string] $ThreadId)
    return Join-Path $IntegrationRoot ('spool\state\fresh-activity\' + (Get-CfnEventId $ThreadId) + '.json')
}

function Get-CfnQueueFreshness {
    param([string] $IntegrationRoot, $Settings, $QueueItem, [datetime] $Now = (Get-Date))
    if (-not [bool](Get-CfnProperty $Settings 'FreshNotificationsOnly' $false)) { return 'eligible' }
    $window = Get-CfnFreshDeliveryWindow $IntegrationRoot $Settings $Now
    if ($null -eq $window) { return 'outside_delivery_window' }
    $created = [datetimeoffset]::Parse([string]$QueueItem.created_at)
    if ($created -lt $window.Start -or $created -ge $window.End) { return 'historical_window' }
    if ($created -gt [datetimeoffset]$Now) { return 'future_timestamp' }
    $startText = [string](Get-CfnProperty $QueueItem 'delivery_window_start' '')
    $endText = [string](Get-CfnProperty $QueueItem 'delivery_window_end' '')
    if (-not $startText -or -not $endText) { return 'legacy_unstamped' }
    $stampedStart = [datetimeoffset]::Parse($startText)
    $stampedEnd = [datetimeoffset]::Parse($endText)
    if ($stampedStart -ne $window.Start -or $created -lt $stampedStart -or $created -ge $stampedEnd -or
        [datetimeoffset]$Now -ge $stampedEnd) { return 'historical_window' }
    if ([string](Get-CfnProperty $QueueItem 'kind' '') -eq 'completed') {
        $threadId = [string](Get-CfnProperty $QueueItem 'thread_id' '')
        if ($threadId) {
            $path = Get-CfnFreshActivityPath $IntegrationRoot $threadId
            if (Test-Path -LiteralPath $path) {
                $activity = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($activity.phase -eq 'running' -or
                    ($activity.event_id -and $activity.event_id -cne [string]$QueueItem.event_id)) { return 'superseded_by_new_activity' }
            }
        }
    }
    return 'eligible'
}

function Move-CfnStaleQueueItem {
    param([string] $IntegrationRoot, [string] $Path, [string] $Reason)
    $root = [IO.Path]::GetFullPath($IntegrationRoot).TrimEnd('\', '/')
    $pending = [IO.Path]::GetFullPath((Join-Path $root 'spool\pending')).TrimEnd('\') + '\'
    $source = [IO.Path]::GetFullPath($Path)
    if (-not $source.StartsWith($pending, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($source) -ine $pending.TrimEnd('\')) { throw 'Queue item is outside the pending directory.' }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $false }
    $targetRoot = [IO.Path]::GetFullPath((Join-Path $root 'spool\suppressed'))
    if (-not $targetRoot.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid suppression directory.' }
    Ensure-CfnDirectory $targetRoot
    $target = Join-Path $targetRoot ([datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N') + '-' + [IO.Path]::GetFileName($source))
    Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
    Write-CfnLog $IntegrationRoot 'queue' 'stale_suppressed' ([IO.Path]::GetFileNameWithoutExtension($source)) $Reason
    return $true
}

function Set-CfnFreshThreadActivity {
    param([string] $IntegrationRoot, $Settings, [string] $ThreadId, [string] $TurnId,
        [ValidateSet('running','completed')] [string] $Phase, [string] $EventId = '')
    if (-not [bool](Get-CfnProperty $Settings 'FreshNotificationsOnly' $false) -or -not $ThreadId) { return $true }
    # Called under the existing lifecycle state mutex, also held during the
    # transport's final submission check. A new turn invalidates unsent completions.
    $path = Get-CfnFreshActivityPath $IntegrationRoot $ThreadId
    if ($Phase -eq 'completed' -and (Test-Path -LiteralPath $path)) {
        $previous = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($previous.phase -eq 'running' -and $previous.turn_id -and $TurnId -and $previous.turn_id -cne $TurnId) { return $false }
    }
    Write-CfnJsonAtomic $path @{ thread_id = $ThreadId; turn_id = $TurnId; phase = $Phase; event_id = $EventId; changed_at = [datetimeoffset]::UtcNow.ToString('o') }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $IntegrationRoot 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string](Get-CfnProperty $item 'kind' '') -eq 'completed' -and
                [string](Get-CfnProperty $item 'thread_id' '') -ceq $ThreadId -and
                [string](Get-CfnProperty $item 'event_id' '') -cne $EventId) {
                [void](Move-CfnStaleQueueItem $IntegrationRoot $file.FullName 'superseded_by_new_activity')
            }
        } catch { Write-CfnLog $IntegrationRoot 'queue' 'stale_check_failed' $file.BaseName }
    }
    return $true
}

function Find-CfnLarkCli {
    param([AllowEmptyString()] [string] $ExplicitPath = '')

    $resolved = Resolve-CfnPath $ExplicitPath
    if ($resolved) {
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
        return $null
    }

    foreach ($name in @('lark-cli.exe', 'lark-cli.cmd', 'lark-cli.ps1', 'lark-cli')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }

    $programsRoot = Join-Path $env:LOCALAPPDATA 'Programs'
    if (Test-Path -LiteralPath $programsRoot) {
        $candidates = Get-ChildItem -LiteralPath $programsRoot -Directory -Filter 'node-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                @(
                    (Join-Path $_.FullName 'lark-cli.ps1'),
                    (Join-Path $_.FullName 'lark-cli.cmd'),
                    (Join-Path $_.FullName 'node_modules\@larksuite\cli\bin\lark-cli.exe')
                )
            } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        if ($candidates) { return @($candidates)[0] }
    }
    return $null
}

function Initialize-CfnLarkProfile {
    param([Parameter(Mandatory = $true)] $Settings)

    if (-not $Settings.RequireLarkProfile) { return }
    if ([string]::IsNullOrWhiteSpace($Settings.LarkChannelHome) -or
        [string]::IsNullOrWhiteSpace($Settings.LarkChannelProfile)) {
        throw 'A Lark channel home and profile are required for lark-cli profile mode.'
    }

    $profileRoot = Join-Path $Settings.LarkChannelHome ('profiles\{0}' -f $Settings.LarkChannelProfile)
    $sourceConfig = Join-Path $profileRoot 'lark-cli-source\config.json'
    $cliConfigDir = Join-Path $profileRoot 'lark-cli'
    if (-not (Test-Path -LiteralPath $sourceConfig) -or -not (Test-Path -LiteralPath $cliConfigDir)) {
        throw "Lark channel profile is not ready: $profileRoot"
    }

    # Authentication overrides are scoped to the transport child, never the GUI process.
}

function New-CfnMessage {
    param(
        [Parameter(Mandatory = $true)] $QueueItem,
        [Parameter(Mandatory = $true)] $Settings
    )

    $kind = [string](Get-CfnProperty $QueueItem 'kind' 'completed')
    $title = if ($kind -eq 'needs-input') {
        ([string]::Concat([char]::ConvertFromUtf32(0x1F7E0), ' Codex 等待授权'))
    } else {
        ([string]::Concat([char]0x2705, ' Codex 本轮回复完成'))
    }
    $lines = @(
        $title,
        ('Workspace: {0}' -f (Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'project' 'Unknown workspace')) 100))
    )
    $taskPreview = Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'task_preview' '')) 300
    $resultPreview = Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'result_preview' '')) 600
    if ($Settings.IncludeTaskPreview -and $taskPreview) { $lines += "Task: $taskPreview" }
    if ($Settings.IncludeResultPreview -and $resultPreview) { $lines += "Result: $resultPreview" }
    $permissionTool = [string](Get-CfnProperty $QueueItem 'permission_tool' '')
    if ($kind -eq 'needs-input' -and $Settings.IncludePermissionTool -and $permissionTool) {
        $lines += "Tool: $(Protect-CfnPreview $permissionTool 80)"
    }
    return $lines -join [Environment]::NewLine
}

function New-CfnCardContent {
    param(
        [Parameter(Mandatory = $true)] $QueueItem,
        [Parameter(Mandatory = $true)] $Settings
    )

    $kind = [string](Get-CfnProperty $QueueItem 'kind' 'completed')
    $title = if ($kind -eq 'needs-input') { 'Codex 等待授权' } else { 'Codex 本轮回复完成' }
    $template = if ($kind -eq 'needs-input') { 'orange' } else { 'green' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('**工作区：** {0}' -f (Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'project' 'Unknown workspace')) 100)))
    $taskPreview = Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'task_preview' '')) 300
    $resultPreview = Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'result_preview' '')) 600
    $permissionTool = [string](Get-CfnProperty $QueueItem 'permission_tool' '')
    if ($Settings.IncludeTaskPreview -and $taskPreview) { $lines.Add("**任务：** $taskPreview") }
    if ($Settings.IncludeResultPreview -and $resultPreview) { $lines.Add("**结果：** $resultPreview") }
    if ($kind -eq 'needs-input' -and $Settings.IncludePermissionTool -and $permissionTool) {
        $lines.Add("**等待工具：** $(Protect-CfnPreview $permissionTool 80)")
    }
    $createdAt = [string](Get-CfnProperty $QueueItem 'created_at' '')
    try {
        $localTime = [datetimeoffset]::Parse($createdAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    } catch {
        $localTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $card = [ordered]@{
        config = [ordered]@{ wide_screen_mode = $true }
        header = [ordered]@{
            template = $template
            title = [ordered]@{ tag = 'plain_text'; content = $title }
        }
        elements = @(
            [ordered]@{
                tag = 'div'
                text = [ordered]@{ tag = 'lark_md'; content = ($lines -join "`n") }
            },
            [ordered]@{
                tag = 'note'
                elements = @([ordered]@{ tag = 'plain_text'; content = "事件时间：$localTime" })
            }
        )
    }
    return $card | ConvertTo-Json -Depth 8 -Compress
}

function Get-CfnDeliveryPayload {
    param(
        [Parameter(Mandatory = $true)] $QueueItem,
        [Parameter(Mandatory = $true)] $Settings
    )

    if ($Settings.MessageFormat -eq 'card') {
        return [pscustomobject]@{
            MessageType = 'interactive'
            ContentFlag = '--content'
            Content = New-CfnCardContent $QueueItem $Settings
        }
    }
    return [pscustomobject]@{
        MessageType = 'text'
        ContentFlag = '--text'
        Content = New-CfnMessage $QueueItem $Settings
    }
}

function Test-CfnTransportOutput {
    param(
        [Parameter(Mandatory = $true)] [int] $ExitCode,
        [AllowEmptyString()] [string] $Output = ''
    )

    if ($ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Reason = "exit=$ExitCode" }
    }
    $trimmed = $Output.Trim()
    if (-not $trimmed) {
        return [pscustomobject]@{ Success = $false; Reason = 'unconfirmed_empty_output'; MessageId = '' }
    }
    try {
        $value = $trimmed | ConvertFrom-Json
        foreach ($name in @('code', 'StatusCode', 'status_code')) {
            $property = $value.PSObject.Properties[$name]
            if ($null -ne $property -and [int]$property.Value -ne 0) {
                return [pscustomobject]@{ Success = $false; Reason = "$name=$($property.Value)" }
            }
        }
        $successProperty = $value.PSObject.Properties['success']
        if ($null -ne $successProperty -and $successProperty.Value -eq $false) {
            return [pscustomobject]@{ Success = $false; Reason = 'success=false' }
        }
        $errorProperty = $value.PSObject.Properties['error']
        if ($null -ne $errorProperty -and $errorProperty.Value) {
            return [pscustomobject]@{ Success = $false; Reason = 'error returned' }
        }
        $code = Get-CfnProperty $value 'code' $null
        $data = Get-CfnProperty $value 'data' $null
        $messageId = [string](Get-CfnProperty $data 'message_id' '')
        if ($null -ne $code -and ($code -is [int] -or $code -is [long]) -and $code -eq 0 -and $messageId -match '^om_[A-Za-z0-9_-]+$') {
            return [pscustomobject]@{ Success = $true; Reason = 'confirmed_receipt'; MessageId = $messageId }
        }
        return [pscustomobject]@{ Success = $false; Reason = 'unconfirmed_response'; MessageId = '' }
    } catch {
        return [pscustomobject]@{ Success = $false; Reason = 'unconfirmed_non_json'; MessageId = '' }
    }
}

function ConvertTo-CfnTomlArray {
    param([Parameter(Mandatory = $true)] [object[]] $Values)

    $encoded = @($Values | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) -Compress })
    return '[ ' + ($encoded -join ', ') + ' ]'
}

function ConvertTo-CfnCanonicalValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        $keys = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        foreach ($key in @($keys | Sort-Object)) { $copy[$key] = ConvertTo-CfnCanonicalValue (Get-CfnProperty $Value $key $null) }
        return $copy
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-CfnCanonicalValue $_ }) }
    return $Value
}

function Get-CfnRequestIdentity {
    param($Event)
    $toolInput = Get-CfnProperty $Event 'tool_input' $null
    $inputHash = ''
    if ($null -ne $toolInput) {
        $normalized = ConvertTo-CfnCanonicalValue $toolInput
        if ($normalized -is [System.Collections.IDictionary]) { $normalized.Remove('description') }
        if ($null -ne $normalized -and ($normalized | ConvertTo-Json -Depth 50 -Compress) -ne '{}') {
            $inputHash = Get-CfnEventId ($normalized | ConvertTo-Json -Depth 50 -Compress)
        }
    }
    return [pscustomobject]@{
        RequestId = [string](Get-CfnProperty $Event 'tool_use_id' (Get-CfnProperty $Event 'request_id' ''))
        InputHash = $inputHash
        ToolName = [string](Get-CfnProperty $Event 'tool_name' '')
        TurnId = [string](Get-CfnProperty $Event 'turn_id' '')
    }
}

function New-CfnPermissionEventId {
    param([string] $IntegrationRoot, [string] $SessionId, $Identity)
    if ($Identity.RequestId) {
        $key = Get-CfnEventId ("request|$SessionId|$($Identity.TurnId)|$($Identity.RequestId)")
        if (Test-Path -LiteralPath (Join-Path $IntegrationRoot "spool\state\resolved\$key.json")) { return '' }
        return $key
    }
    # The synchronous hook updates a local generation under the state mutex.
    $path = Join-Path $IntegrationRoot ('spool\state\generations\' + (Get-CfnEventId $SessionId) + '.json')
    $generation = 0L
    $epoch = [guid]::NewGuid().ToString('N')
    if (Test-Path -LiteralPath $path) {
        $previous = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $generation = [long](Get-CfnProperty $previous 'generation' 0)
        $epoch = [string](Get-CfnProperty $previous 'epoch' $epoch)
    }
    $generation++
    Write-CfnJsonAtomic $path @{ generation = $generation; epoch = $epoch }
    return Get-CfnEventId ("needs-input|$SessionId|$($Identity.TurnId)|$epoch|$generation|$($Identity.ToolName)|$($Identity.InputHash)")
}

function Test-CfnWaitingItemActive {
    param([string] $IntegrationRoot, $QueueItem, [int] $TtlHours = 24)
    if ([string](Get-CfnProperty $QueueItem 'kind' 'completed') -ne 'needs-input') { return $true }
    $eventId = [string](Get-CfnProperty $QueueItem 'event_id' '')
    if ($eventId -notmatch '^[0-9a-f]{40}$') { return $false }
    $path = Join-Path $IntegrationRoot "spool\state\waiting\$eventId.json"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$record.event_id -ceq $eventId -and
            [string]$record.session_id -ceq [string]$QueueItem.thread_id -and
            [datetimeoffset]::Parse($record.waiting_at) -gt [datetimeoffset]::UtcNow.AddHours(-$TtlHours)
    } catch { return $false }
}

function Enter-CfnMutex {
    param([string] $IntegrationRoot, [string] $Scope = 'state', [int] $TimeoutMilliseconds = 5000)
    $rootKey = Get-CfnEventId ([IO.Path]::GetFullPath($IntegrationRoot).TrimEnd('\', '/').ToUpperInvariant())
    $mutex = New-Object Threading.Mutex($false, "Local\CodexFeishuNotify.$rootKey.$Scope")
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if ($acquired) { return $mutex }
        $mutex.Dispose()
        if ($Scope -eq 'state') { throw 'Notification state is busy; retry the operation.' }
        return $null
    } catch { $mutex.Dispose(); throw }
}

function Exit-CfnMutex {
    param([AllowNull()] $Mutex)
    if ($null -ne $Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
}

function Set-CfnDeliveryEnabled {
    param([string] $IntegrationRoot, [bool] $Enabled)
    $lock = Enter-CfnMutex $IntegrationRoot
    if ($null -eq $lock) { throw 'Delivery state is busy; try again.' }
    try {
        $path = Join-Path $IntegrationRoot 'settings.local.json'
        $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $delivery = Get-CfnProperty $document 'delivery' $null
        if ($null -eq $delivery) { $delivery = [pscustomobject]@{}; $document | Add-Member NoteProperty delivery $delivery }
        $delivery | Add-Member NoteProperty enabled $Enabled -Force
        Write-CfnJsonAtomic (Join-Path $IntegrationRoot 'spool\state\runtime-control.json') @{ enabled = $Enabled; changed_at = [datetimeoffset]::UtcNow.ToString('o') }
        Write-CfnJsonAtomic $path $document
    } finally { Exit-CfnMutex $lock }
}

function ConvertTo-CfnNativeArgument {
    param([AllowEmptyString()] [string] $Value)
    # Windows CommandLineToArgvW / CRT quoting; no shell interprets these values.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Resolve-CfnNativeCli {
    param([string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ieq '.exe') { return $full }
    if ([IO.Path]::GetExtension($full) -in @('.cmd', '.ps1')) {
        $shim = (Get-Content -LiteralPath $full -Raw -Encoding UTF8).Replace('\', '/')
        $binary = Join-Path (Split-Path -Parent $full) 'node_modules\@larksuite\cli\bin\lark-cli.exe'
        if ($shim.Contains('node_modules/@larksuite/cli/') -and (Test-Path -LiteralPath $binary -PathType Leaf)) { return $binary }
    }
    throw 'Unsupported lark-cli wrapper. Select lark-cli.exe or the official npm lark-cli.cmd / lark-cli.ps1 shim.'
}

function Invoke-CfnTransport {
    param([string] $IntegrationRoot, [string] $CliPath, [string[]] $Arguments, $Settings, $QueueItem = $null)
    $process = New-Object Diagnostics.Process
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Resolve-CfnNativeCli $CliPath
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CfnNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $start.EnvironmentVariables['LARKSUITE_CLI_NO_UPDATE_NOTIFIER'] = '1'
    $start.EnvironmentVariables['LARKSUITE_CLI_NO_SKILLS_NOTIFIER'] = '1'
    if ($Settings.RequireLarkProfile) {
        $profileRoot = Join-Path $Settings.LarkChannelHome ('profiles\' + $Settings.LarkChannelProfile)
        $start.EnvironmentVariables['LARK_CHANNEL'] = '1'
        $start.EnvironmentVariables['LARK_CHANNEL_HOME'] = $Settings.LarkChannelHome
        $start.EnvironmentVariables['LARK_CHANNEL_PROFILE'] = $Settings.LarkChannelProfile
        $start.EnvironmentVariables['LARK_CHANNEL_CONFIG'] = Join-Path $profileRoot 'lark-cli-source\config.json'
        $start.EnvironmentVariables['LARKSUITE_CLI_CONFIG_DIR'] = Join-Path $profileRoot 'lark-cli'
    } else {
        foreach ($name in @('LARK_CHANNEL', 'LARK_CHANNEL_HOME', 'LARK_CHANNEL_PROFILE', 'LARK_CHANNEL_CONFIG', 'LARKSUITE_CLI_CONFIG_DIR')) {
            $start.EnvironmentVariables.Remove($name)
        }
    }
    $process.StartInfo = $start
    try {
        # One short shared lock makes pause/disable and the next submission atomic.
        # It is released after Start(), so controls do not wait for a network call.
        $lock = Enter-CfnMutex $IntegrationRoot
        if ($null -eq $lock) { throw 'Delivery state is busy.' }
        try {
            $current = Get-CfnSettings $IntegrationRoot
            $control = Get-CfnDeliveryControlState $IntegrationRoot $current
            if (-not $current.FeishuEnabled -or -not $control.EffectiveActive) {
                return [pscustomobject]@{ ExitCode = -2; Stdout = ''; Stderr = ''; Skipped = $true; TimedOut = $false }
            }
            if ($null -ne $QueueItem -and -not (Test-CfnWaitingItemActive $IntegrationRoot $QueueItem $current.WaitingStateTtlHours)) {
                return [pscustomobject]@{ ExitCode = -2; Stdout = ''; Stderr = ''; Skipped = $true; TimedOut = $false }
            }
            if ($null -ne $QueueItem -and (Get-CfnQueueFreshness $IntegrationRoot $current $QueueItem) -ne 'eligible') {
                return [pscustomobject]@{ ExitCode = -2; Stdout = ''; Stderr = ''; Skipped = $true; TimedOut = $false }
            }
            if ($current.ChatId -cne $Settings.ChatId -or $current.LarkChannelProfile -cne $Settings.LarkChannelProfile -or
                $current.LarkChannelHome -cne $Settings.LarkChannelHome -or $current.RequireLarkProfile -ne $Settings.RequireLarkProfile -or
                $current.IncludeTaskPreview -ne $Settings.IncludeTaskPreview -or $current.IncludeResultPreview -ne $Settings.IncludeResultPreview -or
                $current.IncludePermissionTool -ne $Settings.IncludePermissionTool -or
                $current.LarkCliPath -cne $Settings.LarkCliPath -or $current.MessageFormat -cne $Settings.MessageFormat) {
                return [pscustomobject]@{ ExitCode = -2; Stdout = ''; Stderr = ''; Skipped = $true; TimedOut = $false }
            }
            [void]$process.Start()
        } finally { Exit-CfnMutex $lock }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($Settings.SendTimeoutSeconds * 1000)
        if (-not $finished) {
            try { $process.Kill() } catch {}
            [void]$process.WaitForExit(3000)
        }
        # WaitForExit does not guarantee asynchronous stream continuations have run.
        [void]$stdoutTask.Wait(3000)
        [void]$stderrTask.Wait(3000)
        return [pscustomobject]@{
            ExitCode = if ($finished) { $process.ExitCode } else { -1 }
            Stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
            Stderr = if ($stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() } else { '' }
            TimedOut = (-not $finished); Skipped = $false
        }
    } finally { $process.Dispose() }
}

function Update-CfnDeliveryResult {
    param([string] $IntegrationRoot, [string] $Status, [string] $Reason = '', [string] $EventId = '', [string] $MessageId = '')
    $path = Join-Path $IntegrationRoot 'spool\state\delivery-result.json'
    $previous = if (Test-Path -LiteralPath $path) { try { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
    $now = [datetimeoffset]::UtcNow.ToString('o')
    Write-CfnJsonAtomic $path ([ordered]@{
        at = $now; status = $Status; reason = $Reason; event_id = $EventId
        last_success_at = if ($Status -eq 'sent') { $now } else { Get-CfnProperty $previous 'last_success_at' '' }
        last_message_id = if ($MessageId) { $MessageId } else { Get-CfnProperty $previous 'last_message_id' '' }
    })
}

function Invoke-CfnRetention {
    param([string] $IntegrationRoot, $Settings)
    $stateLock = Enter-CfnMutex $IntegrationRoot 'state'
    try {
    foreach ($entry in @(
        @('spool\sent', '*.sent', ($Settings.SentMarkerRetentionDays * 24)),
        @('spool\expired', '*.json', ($Settings.ExpiredItemRetentionDays * 24)),
        @('spool\suppressed', '*.json', ($Settings.SuppressedItemRetentionDays * 24)),
        @('spool\state\waiting', '*.json', $Settings.WaitingStateTtlHours),
        @('spool\state\resolved', '*.json', $Settings.WaitingStateTtlHours),
        @('spool\state\completion', '*.json', ($Settings.CompletionArmTtlMinutes / 60.0)),
        @('spool\state\ready', '*.json', $Settings.ReadyStateTtlHours),
        @('spool\state\generations', '*.json', $Settings.WaitingStateTtlHours),
        @('spool\state\fresh-activity', '*.json', $Settings.ReadyStateTtlHours)
    )) {
        $cutoff = [datetime]::UtcNow.AddHours(-[double]$entry[2])
        Get-ChildItem -LiteralPath (Join-Path $IntegrationRoot $entry[0]) -File -Filter $entry[1] -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    } finally { Exit-CfnMutex $stateLock }
}

Export-ModuleMember -Function @(
    'Get-CfnFreshDeliveryWindow', 'Set-CfnQueueDeliveryWindow', 'Get-CfnQueueFreshness', 'Move-CfnStaleQueueItem', 'Set-CfnFreshThreadActivity',
    'Get-CfnRequestIdentity', 'New-CfnPermissionEventId', 'Test-CfnWaitingItemActive',
    'Get-CfnCodexHome', 'Enter-CfnMutex', 'Exit-CfnMutex', 'Set-CfnDeliveryEnabled',
    'ConvertTo-CfnNativeArgument', 'Resolve-CfnNativeCli', 'Invoke-CfnTransport', 'Update-CfnDeliveryResult', 'Invoke-CfnRetention',
    'Get-CfnProperty',
    'Resolve-CfnPath',
    'Ensure-CfnDirectory',
    'Write-CfnLog',
    'Get-CfnSettings',
    'Protect-CfnPreview',
    'Test-CfnInternalPrompt',
    'Test-CfnVisibleThread',
    'Get-CfnEventId',
    'Write-CfnJsonAtomic',
    'Move-CfnPendingToSuppressed',
    'Get-CfnStateFile',
    'Set-CfnLifecycleReady',
    'Test-CfnLifecycleReady',
    'Set-CfnCompletionArm',
    'Use-CfnCompletionArm',
    'Set-CfnWaitingState',
    'Resolve-CfnWaitingState',
    'Test-CfnCodexForeground',
    'New-CfnToastXml',
    'Show-CfnToast',
    'Remove-CfnToast',
    'Show-CfnDesktopEvent',
    'ConvertTo-CfnIsoDuration',
    'Get-CfnScheduleWindow',
    'Get-CfnHolidayCalendar',
    'Get-CfnHolidayGapWindows',
    'Get-CfnManualDeliveryStatePath',
    'Get-CfnManualDeliveryState',
    'Set-CfnManualDeliveryState',
    'Clear-CfnManualDeliveryState',
    'Test-CfnAllDayDate',
    'Test-CfnScheduleActive',
    'Get-CfnNextScheduleStart',
    'Get-CfnDeliveryControlState',
    'Find-CfnLarkCli',
    'Initialize-CfnLarkProfile',
    'New-CfnMessage',
    'New-CfnCardContent',
    'Get-CfnDeliveryPayload',
    'Test-CfnTransportOutput',
    'ConvertTo-CfnTomlArray'
)
