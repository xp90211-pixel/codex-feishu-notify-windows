Set-StrictMode -Version 2.0

function Get-CfnProperty {
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        $Default = $null
    )

    if ($null -ne $Object) {
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
        $safeDetail = ($Detail -replace '[\r\n]+', ' ')
        $safeDetail = $safeDetail -replace '(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [REDACTED]'
        $safeDetail = $safeDetail -replace '(?i)\bsk-[A-Za-z0-9_-]{12,}\b', 'sk-[REDACTED]'
        $safeDetail = $safeDetail -replace '(?i)(api[_-]?key|token|secret|password|webhook)\s*[:=]\s*\S+', '$1=[REDACTED]'
        if ($safeDetail.Length -gt 300) { $safeDetail = $safeDetail.Substring(0, 300) }
        $entry = [ordered]@{
            at = (Get-Date).ToUniversalTime().ToString('o')
            stage = $Stage
            status = $Status
            event_id = $EventId
            detail = $safeDetail
        }
        $path = Join-Path $logRoot 'notify.jsonl'
        Add-Content -LiteralPath $path -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
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
        VisibleThreadsOnly = [bool](Get-CfnProperty $filters 'visible_threads_only' $true)
        SkipBridgeOrigin = [bool](Get-CfnProperty $filters 'skip_bridge_origin' $true)
        IncludeTaskPreview = [bool](Get-CfnProperty $message 'include_task_preview' $true)
        IncludeResultPreview = [bool](Get-CfnProperty $message 'include_result_preview' $true)
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
        ScheduleEnd = [string](Get-CfnProperty $delivery 'end' '02:00')
        IntervalMinutes = [int](Get-CfnProperty $delivery 'interval_minutes' 1)
        HolidayRegion = [string](Get-CfnProperty $delivery 'holiday_region' 'None')
        HolidayCalendarPath = $holidayCalendarPath
        AllDayWeekdays = $allDayWeekdays
        MaxQueueAgeHours = [int](Get-CfnProperty $delivery 'max_queue_age_hours' 24)
        SentMarkerRetentionDays = [int](Get-CfnProperty $delivery 'sent_marker_retention_days' 90)
        ExpiredItemRetentionDays = [int](Get-CfnProperty $delivery 'expired_item_retention_days' 7)
    }
    if ($settings.MessageFormat -notin @('text', 'card')) { throw 'Message format must be text or card.' }
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

function Protect-CfnPreview {
    param(
        [AllowEmptyString()] [string] $Text,
        [ValidateRange(1, 4000)] [int] $Limit
    )

    if ($null -eq $Text) { return '' }
    $value = ($Text -replace '[\x00-\x1f]+', ' ' -replace '\s+', ' ').Trim()
    $value = $value -replace '(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [REDACTED]'
    $value = $value -replace '(?i)\bsk-[A-Za-z0-9_-]{12,}\b', 'sk-[REDACTED]'
    $value = $value -replace '(?i)(api[_-]?key|token|secret|password|webhook)\s*[:=]\s*\S+', '$1=[REDACTED]'
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
        [string] $StatePath = (Join-Path $env:USERPROFILE '.codex\.codex-global-state.json')
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) { return $false }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $false }
    try {
        $stateText = Get-Content -LiteralPath $StatePath -Raw
        $quotedId = '"' + $ThreadId + '"'
        $referenceKey = '"thread-reference-capability:' + $ThreadId + '"'
        return ($stateText.IndexOf($quotedId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
               ($stateText.IndexOf($referenceKey, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
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
        [System.IO.File]::WriteAllText($tempPath, ($Value | ConvertTo-Json -Depth 8 -Compress), $utf8NoBom)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
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
        [Parameter(Mandatory = $true)] [string] $ToastTag
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $path = Get-CfnStateFile $IntegrationRoot 'waiting' $SessionId
    Write-CfnJsonAtomic $path ([ordered]@{
        schema = 1
        session_id = $SessionId
        event_id = $EventId
        toast_tag = $ToastTag
        waiting_at = [datetimeoffset]::UtcNow.ToString('o')
    })
    return $true
}

function Resolve-CfnWaitingState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [ValidateRange(1, 168)] [int] $TtlHours = 24
    )

    $result = [ordered]@{ Found = $false; EventId = ''; PendingRemoved = $false; ToastRemoved = $false; Stale = $false }
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return [pscustomobject]$result }
    $path = Get-CfnStateFile $IntegrationRoot 'waiting' $SessionId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]$result }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-CfnProperty $record 'session_id' '') -ne $SessionId) { return [pscustomobject]$result }
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
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    } catch {
        Write-CfnLog $IntegrationRoot 'state' 'waiting_resolve_failed' '' $_.Exception.Message
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

    $path = Get-CfnManualDeliveryStatePath $IntegrationRoot
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Set-CfnManualDeliveryState {
    param(
        [Parameter(Mandatory = $true)] [string] $IntegrationRoot,
        [Parameter(Mandatory = $true)] [ValidateSet('force', 'pause')] [string] $Mode,
        [Parameter(Mandatory = $true)] [datetimeoffset] $ExpiresAt,
        [datetimeoffset] $Now = [datetimeoffset]::Now
    )

    if ($ExpiresAt -le $Now) { throw 'Manual delivery override must expire in the future.' }
    $path = Get-CfnManualDeliveryStatePath $IntegrationRoot
    Write-CfnJsonAtomic $path ([ordered]@{
        schema = 1
        mode = $Mode
        created_at = $Now.ToUniversalTime().ToString('o')
        expires_at = $ExpiresAt.ToUniversalTime().ToString('o')
    })
    return Get-CfnManualDeliveryState $IntegrationRoot -Now $Now
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
            Clear-CfnManualDeliveryState $IntegrationRoot
            return $null
        }
        return [pscustomobject]@{
            Mode = $mode
            CreatedAt = [datetimeoffset]::Parse([string](Get-CfnProperty $record 'created_at' '')).ToUniversalTime()
            ExpiresAt = $expiresAt
            Path = $path
        }
    } catch {
        # A corrupt or stale override must never leave delivery permanently on
        # or off. Remove it and fall back to the saved schedule.
        Clear-CfnManualDeliveryState $IntegrationRoot
        return $null
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
    return [pscustomobject]@{
        ScheduledActive = [bool]$scheduled
        EffectiveActive = [bool]$effective
        Reason = $reason
        ManualMode = $mode
        ManualExpiresAt = if ($null -ne $manual) { $manual.ExpiresAt } else { $null }
        NextScheduleStart = Get-CfnNextScheduleStart $Settings $Now
    }
}

function Find-CfnLarkCli {
    param([AllowEmptyString()] [string] $ExplicitPath = '')

    $resolved = Resolve-CfnPath $ExplicitPath
    if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $resolved }

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

    $env:LARK_CHANNEL = '1'
    $env:LARK_CHANNEL_HOME = $Settings.LarkChannelHome
    $env:LARK_CHANNEL_PROFILE = $Settings.LarkChannelProfile
    $env:LARK_CHANNEL_CONFIG = $sourceConfig
    $env:LARKSUITE_CLI_CONFIG_DIR = $cliConfigDir
    $env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
    $env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'
}

function New-CfnMessage {
    param(
        [Parameter(Mandatory = $true)] $QueueItem,
        [Parameter(Mandatory = $true)] $Settings
    )

    $kind = [string](Get-CfnProperty $QueueItem 'kind' 'completed')
    $title = if ($kind -eq 'needs-input') {
        ([string]::Concat([char]0x1F7E0, ' Codex 等待授权'))
    } else {
        ([string]::Concat([char]0x2705, ' Codex 任务完成'))
    }
    $lines = @(
        $title,
        ('Workspace: {0}' -f [string](Get-CfnProperty $QueueItem 'project' 'Unknown workspace'))
    )
    $taskPreview = [string](Get-CfnProperty $QueueItem 'task_preview' '')
    $resultPreview = [string](Get-CfnProperty $QueueItem 'result_preview' '')
    if ($Settings.IncludeTaskPreview -and $taskPreview) { $lines += "Task: $taskPreview" }
    if ($Settings.IncludeResultPreview -and $resultPreview) { $lines += "Result: $resultPreview" }
    $permissionTool = [string](Get-CfnProperty $QueueItem 'permission_tool' '')
    if ($kind -eq 'needs-input' -and $Settings.IncludePermissionTool -and $permissionTool) {
        $lines += "Tool: $permissionTool"
    }
    return $lines -join [Environment]::NewLine
}

function New-CfnCardContent {
    param(
        [Parameter(Mandatory = $true)] $QueueItem,
        [Parameter(Mandatory = $true)] $Settings
    )

    $kind = [string](Get-CfnProperty $QueueItem 'kind' 'completed')
    $title = if ($kind -eq 'needs-input') { 'Codex 等待授权' } else { 'Codex 任务完成' }
    $template = if ($kind -eq 'needs-input') { 'orange' } else { 'green' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('**工作区：** {0}' -f (Protect-CfnPreview ([string](Get-CfnProperty $QueueItem 'project' 'Unknown workspace')) 100)))
    $taskPreview = [string](Get-CfnProperty $QueueItem 'task_preview' '')
    $resultPreview = [string](Get-CfnProperty $QueueItem 'result_preview' '')
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
                elements = @([ordered]@{ tag = 'plain_text'; content = "本机时间：$localTime" })
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
        return [pscustomobject]@{ Success = $true; Reason = 'exit=0' }
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
        return [pscustomobject]@{ Success = $true; Reason = 'json_ok' }
    } catch {
        return [pscustomobject]@{ Success = $true; Reason = 'exit=0_non_json' }
    }
}

function ConvertTo-CfnTomlArray {
    param([Parameter(Mandatory = $true)] [object[]] $Values)

    $encoded = @($Values | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) -Compress })
    return '[ ' + ($encoded -join ', ') + ' ]'
}

Export-ModuleMember -Function @(
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
