Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $IntegrationRoot 'CodexFeishuNotify.psm1') -Force -DisableNameChecking
$eventName = ''

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-CfnLog $IntegrationRoot 'hook' 'empty_payload'
        exit 0
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($raw) -gt 1048576) {
        Write-CfnLog $IntegrationRoot 'hook' 'payload_too_large'
        exit 0
    }

    $event = $raw | ConvertFrom-Json
    $eventName = [string](Get-CfnProperty $event 'hook_event_name' '')
    $settings = Get-CfnSettings $IntegrationRoot
    $sessionId = ([string](Get-CfnProperty $event 'session_id' '')).Trim()
    $turnId = ([string](Get-CfnProperty $event 'turn_id' '')).Trim()

    $forceQueue = ($env:CODEX_FEISHU_NOTIFY_FORCE -eq '1')
    if ($settings.SkipBridgeOrigin -and $env:LARK_CHANNEL -eq '1' -and -not $forceQueue) {
        Write-CfnLog $IntegrationRoot 'hook' 'bridge_origin_skipped' '' $eventName
    } elseif ($eventName -eq 'SessionStart') {
        $ready = Set-CfnLifecycleReady $IntegrationRoot $sessionId
        Write-CfnLog $IntegrationRoot 'hook' $(if ($ready) { 'session_ready' } else { 'session_ready_failed' }) '' $sessionId
    } elseif ($eventName -in @('PostToolUse', 'UserPromptSubmit')) {
        $resolved = Resolve-CfnWaitingState $IntegrationRoot $sessionId $settings.WaitingStateTtlHours
        if ($resolved.Found) {
            $status = if ($resolved.PendingRemoved) { 'waiting_cancelled_before_send' } else { 'waiting_resolved' }
            Write-CfnLog $IntegrationRoot 'hook' $status $resolved.EventId $eventName
        }
    } elseif ($eventName -eq 'Stop') {
        $resolved = Resolve-CfnWaitingState $IntegrationRoot $sessionId $settings.WaitingStateTtlHours
        if ($resolved.Found) { Write-CfnLog $IntegrationRoot 'hook' 'waiting_resolved' $resolved.EventId 'Stop' }

        if (-not $sessionId) {
            Write-CfnLog $IntegrationRoot 'gate' 'missing_session_id'
        } elseif ($settings.VisibleThreadsOnly -and -not (Test-CfnVisibleThread $sessionId)) {
            Write-CfnLog $IntegrationRoot 'gate' 'non_visible_stop_skipped' '' $sessionId
        } else {
            $armed = Set-CfnCompletionArm $IntegrationRoot $sessionId $turnId
            Write-CfnLog $IntegrationRoot 'gate' $(if ($armed) { 'armed' } else { 'arm_failed' }) '' $sessionId
        }
    } elseif ($eventName -eq 'PermissionRequest') {
        if (-not $settings.NotifyPermissionRequests) {
            Write-CfnLog $IntegrationRoot 'hook' 'permission_notification_disabled'
        } elseif (-not $sessionId) {
            Write-CfnLog $IntegrationRoot 'hook' 'permission_missing_session'
        } elseif ($settings.VisibleThreadsOnly -and -not (Test-CfnVisibleThread $sessionId)) {
            Write-CfnLog $IntegrationRoot 'hook' 'permission_non_visible_skipped' '' $sessionId
        } else {
            $previous = Resolve-CfnWaitingState $IntegrationRoot $sessionId $settings.WaitingStateTtlHours
            if ($previous.Found) { Write-CfnLog $IntegrationRoot 'hook' 'previous_waiting_replaced' $previous.EventId }

            $toolName = Protect-CfnPreview ([string](Get-CfnProperty $event 'tool_name' '')) 80
            $eventId = Get-CfnEventId "needs-input|$sessionId|$turnId|$toolName"
            $cwd = [string](Get-CfnProperty $event 'cwd' '')
            $project = if ($cwd) { Split-Path -Leaf $cwd.TrimEnd([char[]]@('\', '/')) } else { 'Local task' }
            if (-not $project) { $project = 'Local task' }
            $item = [ordered]@{
                schema = 2
                kind = 'needs-input'
                event_id = $eventId
                thread_id = $sessionId
                turn_id = $turnId
                created_at = [datetimeoffset]::UtcNow.ToString('o')
                project = Protect-CfnPreview $project 100
                task_preview = ''
                result_preview = ''
                permission_tool = if ($settings.IncludePermissionTool) { $toolName } else { '' }
            }
            $shouldNotify = $true
            if ($settings.FeishuEnabled) {
                $pendingRoot = Join-Path $IntegrationRoot 'spool\pending'
                $sentRoot = Join-Path $IntegrationRoot 'spool\sent'
                Ensure-CfnDirectory $pendingRoot
                Ensure-CfnDirectory $sentRoot
                $pendingPath = Join-Path $pendingRoot "$eventId.json"
                $sentPath = Join-Path $sentRoot "$eventId.sent"
                if ((Test-Path -LiteralPath $pendingPath) -or (Test-Path -LiteralPath $sentPath)) {
                    Write-CfnLog $IntegrationRoot 'hook' 'permission_duplicate' $eventId
                    $shouldNotify = $false
                } else {
                    Write-CfnJsonAtomic $pendingPath $item
                }
            }

            if ($shouldNotify) {
                $toastTag = $eventId.Substring(0, [math]::Min(64, $eventId.Length))
                [void](Set-CfnWaitingState $IntegrationRoot $sessionId $eventId $toastTag)
                $desktopBody = "工作区 $($item.project) 正在等待授权。"
                if ($settings.IncludePermissionTool -and $toolName) { $desktopBody += " 工具：$toolName" }
                [void](Show-CfnDesktopEvent $IntegrationRoot $settings 'needs-input' $desktopBody $toastTag)
                $status = if ($settings.FeishuEnabled) { 'permission_queued' } else { 'permission_feishu_disabled_desktop_only' }
                Write-CfnLog $IntegrationRoot 'hook' $status $eventId
            }
        }
    } else {
        Write-CfnLog $IntegrationRoot 'hook' 'ignored_event' '' $eventName
    }
} catch {
    Write-CfnLog $IntegrationRoot 'hook' 'exception' '' $_.Exception.Message
}

# Stop hooks require valid JSON on stdout. This notifier never blocks or
# continues a task; it only arms the separate completion notification gate.
if ($eventName -eq 'Stop') {
    [Console]::Out.Write('{"continue":true}')
}
exit 0
