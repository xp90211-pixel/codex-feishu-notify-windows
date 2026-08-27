param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $NotificationPayload
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $IntegrationRoot 'CodexFeishuNotify.psm1') -Force -DisableNameChecking
$PayloadJson = ($NotificationPayload -join ' ').Trim()

try {
    $settings = Get-CfnSettings $IntegrationRoot
    if (-not $PayloadJson) {
        Write-CfnLog $IntegrationRoot 'enqueue' 'empty_payload'
        return
    }

    $event = $PayloadJson | ConvertFrom-Json
    $eventType = [string](Get-CfnProperty $event 'type' '')
    if ($eventType -ne 'agent-turn-complete') {
        Write-CfnLog $IntegrationRoot 'enqueue' 'ignored_type' '' $eventType
        return
    }

    $forceQueue = ($env:CODEX_FEISHU_NOTIFY_FORCE -eq '1')
    if ($settings.SkipBridgeOrigin -and $env:LARK_CHANNEL -eq '1' -and -not $forceQueue) {
        Write-CfnLog $IntegrationRoot 'filter' 'bridge_origin_skipped'
        return
    }

    $threadId = ([string](Get-CfnProperty $event 'thread-id' '')).Trim()
    $turnId = ([string](Get-CfnProperty $event 'turn-id' '')).Trim()
    $inputValue = Get-CfnProperty $event 'input-messages' @()
    $inputText = (@($inputValue) | ForEach-Object { [string]$_ }) -join ' | '

    if (Test-CfnInternalPrompt $inputText) {
        Write-CfnLog $IntegrationRoot 'filter' 'internal_turn_skipped' '' $threadId
        return
    }
    if ($settings.VisibleThreadsOnly -and -not (Test-CfnVisibleThread $threadId)) {
        Write-CfnLog $IntegrationRoot 'filter' 'non_visible_thread_skipped' '' $threadId
        return
    }

    if ($settings.StrictCompletionGate) {
        if (Test-CfnLifecycleReady $IntegrationRoot $threadId $settings.ReadyStateTtlHours) {
            if (-not (Use-CfnCompletionArm $IntegrationRoot $threadId $turnId $settings.CompletionArmTtlMinutes)) {
                Write-CfnLog $IntegrationRoot 'gate' 'unarmed_completion_skipped' '' $threadId
                return
            }
            Write-CfnLog $IntegrationRoot 'gate' 'released' '' $threadId
        } else {
            # Sessions that were already open when hooks were installed have no
            # SessionStart marker. Preserve their existing notifications until
            # Codex restarts; new sessions automatically use the strict gate.
            Write-CfnLog $IntegrationRoot 'gate' 'legacy_session_compatibility' '' $threadId
        }
    } else {
        [void](Use-CfnCompletionArm $IntegrationRoot $threadId $turnId $settings.CompletionArmTtlMinutes)
    }

    $resolved = Resolve-CfnWaitingState $IntegrationRoot $threadId $settings.WaitingStateTtlHours
    if ($resolved.Found) { Write-CfnLog $IntegrationRoot 'notify' 'waiting_resolved' $resolved.EventId }

    $idMaterial = if ($threadId -or $turnId) { "$threadId|$turnId" } else { $PayloadJson }
    $eventId = Get-CfnEventId $idMaterial
    $cwd = [string](Get-CfnProperty $event 'cwd' '')
    $project = if ($cwd) { Split-Path -Leaf $cwd.TrimEnd([char[]]@('\', '/')) } else { 'Unknown workspace' }
    if (-not $project) { $project = 'Local task' }
    $assistantMessage = [string](Get-CfnProperty $event 'last-assistant-message' '')
    $queueItem = [ordered]@{
        schema = 2
        kind = 'completed'
        event_id = $eventId
        thread_id = $threadId
        turn_id = $turnId
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        project = Protect-CfnPreview $project 100
        task_preview = if ($settings.IncludeTaskPreview) { Protect-CfnPreview $inputText 180 } else { '' }
        result_preview = if ($settings.IncludeResultPreview) { Protect-CfnPreview $assistantMessage 260 } else { '' }
    }
    $desktopBody = "工作区 $($queueItem.project) 已完成。"
    if ($settings.IncludeResultPreview -and $queueItem.result_preview) {
        $desktopBody += " $($queueItem.result_preview)"
    }

    if (-not $settings.FeishuEnabled) {
        [void](Show-CfnDesktopEvent $IntegrationRoot $settings 'completed' $desktopBody $eventId)
        Write-CfnLog $IntegrationRoot 'enqueue' 'feishu_disabled_desktop_only' $eventId
        return
    }

    # Eligible Feishu notifications intentionally do not follow the desktop
    # foreground notification mode. Delivery timing belongs to the task only.
    $spoolRoot = Join-Path $IntegrationRoot 'spool'
    $pendingRoot = Join-Path $spoolRoot 'pending'
    $sentRoot = Join-Path $spoolRoot 'sent'
    Ensure-CfnDirectory $pendingRoot
    Ensure-CfnDirectory $sentRoot

    $pendingPath = Join-Path $pendingRoot "$eventId.json"
    $sentPath = Join-Path $sentRoot "$eventId.sent"
    if ((Test-Path -LiteralPath $pendingPath) -or (Test-Path -LiteralPath $sentPath)) {
        Write-CfnLog $IntegrationRoot 'enqueue' 'duplicate' $eventId
        return
    }

    $tempPath = Join-Path $pendingRoot "$eventId.$PID.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, ($queueItem | ConvertTo-Json -Compress), $utf8NoBom)
    Move-Item -LiteralPath $tempPath -Destination $pendingPath -Force
    Write-CfnLog $IntegrationRoot 'enqueue' 'queued' $eventId

    [void](Show-CfnDesktopEvent $IntegrationRoot $settings 'completed' $desktopBody $eventId)

    # Do not call Start-ScheduledTask here. Items wait for the registered daily
    # window or a date-specific public-holiday extension.
    Write-CfnLog $IntegrationRoot 'trigger' 'scheduled_only' $eventId
} catch {
    Write-CfnLog $IntegrationRoot 'enqueue' 'exception' '' $_.Exception.Message
}

return
