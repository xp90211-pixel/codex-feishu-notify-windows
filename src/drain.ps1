param(
    [switch] $DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $IntegrationRoot 'CodexFeishuNotify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $IntegrationRoot 'CfnIdleReminder.psm1') -Force -DisableNameChecking
$pendingRoot = Join-Path $IntegrationRoot 'spool\pending'
$sentRoot = Join-Path $IntegrationRoot 'spool\sent'
$expiredRoot = Join-Path $IntegrationRoot 'spool\expired'
$workerLock = $null
$resultCode = 0

try {
    $settings = Get-CfnSettings $IntegrationRoot
    # DryRun never writes logs/state, moves files, invokes the CLI, or cleans up.
    if (-not $DryRun) {
        $workerLock = Enter-CfnMutex $IntegrationRoot 'drain' 0
        if ($null -eq $workerLock) { exit 0 }
        $control = Get-CfnDeliveryControlState $IntegrationRoot $settings
        if (-not $settings.FeishuEnabled -or -not $control.EffectiveActive) {
            $reason = if (-not $settings.FeishuEnabled) { 'feishu_disabled' } else { $control.Reason }
            Update-CfnDeliveryResult $IntegrationRoot 'paused' $reason
            Invoke-CfnRetention $IntegrationRoot $settings
            exit 0
        }
        foreach ($path in @($sentRoot, $expiredRoot)) { Ensure-CfnDirectory $path }
        try { Invoke-CfnIdleReminder $IntegrationRoot $settings $control }
        catch { Write-CfnLog $IntegrationRoot 'all_idle' 'check_failed' }
    }

    $files = @(Get-ChildItem -LiteralPath $pendingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc, Name)
    foreach ($file in $files) {
        try {
            if (-not (Test-Path -LiteralPath $file.FullName)) { continue }
            $settings = Get-CfnSettings $IntegrationRoot
            if (-not $DryRun) {
                $control = Get-CfnDeliveryControlState $IntegrationRoot $settings
                if (-not $settings.FeishuEnabled -or -not $control.EffectiveActive) { break }
            }
            $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $eventId = [string](Get-CfnProperty $item 'event_id' '')
            if ($eventId -notmatch '^[0-9a-f]{40}$' -or $file.BaseName -cne $eventId) { throw 'Invalid queue identity.' }
            $createdAt = [datetimeoffset]::Parse([string](Get-CfnProperty $item 'created_at' ''))
            $expired = $createdAt -lt [datetimeoffset]::UtcNow.AddHours(-$settings.MaxQueueAgeHours)
            if ([string](Get-CfnProperty $item 'kind' '') -eq 'all-idle') {
                $expired = $expired -or (Get-Date) -ge [datetime]::Parse([string]$item.window_end)
            }
            $sentPath = Join-Path $sentRoot "$eventId.sent"
            $alreadySent = Test-Path -LiteralPath $sentPath
            $active = Test-CfnWaitingItemActive $IntegrationRoot $item $settings.WaitingStateTtlHours
            $freshness = Get-CfnQueueFreshness $IntegrationRoot $settings $item
            if ($DryRun) {
                $reason = if ($expired) { 'expired' } elseif ($alreadySent) { 'already_sent' } elseif (-not $active) { 'resolved_or_stale' } else { $freshness }
                $previewPayload = if ([string](Get-CfnProperty $item 'kind' '') -eq 'all-idle') { Get-CfnIdleDeliveryPayload $item $settings } else { Get-CfnDeliveryPayload $item $settings }
                [pscustomobject]@{ EventId = $eventId; State = $reason; Payload = $previewPayload }
                continue
            }
            if ($alreadySent) { Remove-Item -LiteralPath $file.FullName -Force; continue }
            if ($freshness -ne 'eligible') {
                $stateLock = Enter-CfnMutex $IntegrationRoot
                if ($null -eq $stateLock) { throw 'Notification state is busy.' }
                try { [void](Move-CfnStaleQueueItem $IntegrationRoot $file.FullName $freshness) }
                finally { Exit-CfnMutex $stateLock }
                continue
            }
            if ($expired -or -not $active) {
                if (Test-Path -LiteralPath $file.FullName) { Move-Item -LiteralPath $file.FullName -Destination (Join-Path $expiredRoot $file.Name) -Force }
                continue
            }
            if ($settings.TransportType -ne 'lark-cli') { throw 'Unsupported transport.' }
            if ($settings.ChatId -notmatch '^oc_[A-Za-z0-9_-]{8,}$' -or $settings.ChatId -match 'REPLACE') { throw 'Feishu chat ID is missing.' }
            Initialize-CfnLarkProfile $settings
            $cli = Find-CfnLarkCli $settings.LarkCliPath
            if (-not $cli) { throw 'lark-cli was not found.' }
            $payload = if ([string](Get-CfnProperty $item 'kind' '') -eq 'all-idle') { Get-CfnIdleDeliveryPayload $item $settings } else { Get-CfnDeliveryPayload $item $settings }
            $arguments = @('im', '+messages-send', '--as', 'bot', '--chat-id', $settings.ChatId)
            if ($payload.MessageType -eq 'interactive') { $arguments += @('--msg-type', 'interactive') }
            $arguments += @($payload.ContentFlag, $payload.Content, '--idempotency-key', "cx-$eventId", '--format', 'json')

            $receipt = $null
            for ($attempt = 1; $attempt -le $settings.SendAttemptsPerRun; $attempt++) {
                $transport = Invoke-CfnTransport $IntegrationRoot $cli $arguments $settings $item
                if ($transport.Skipped) { break }
                $receipt = Test-CfnTransportOutput $transport.ExitCode $transport.Stdout
                if ($receipt.Success) { break }
                $reason = if ($transport.TimedOut) { 'timeout_unconfirmed' } else { $receipt.Reason }
                # Do not persist raw stdout/stderr: third-party output can echo payloads.
                Update-CfnDeliveryResult $IntegrationRoot 'unconfirmed' $reason $eventId
                Write-CfnLog $IntegrationRoot 'drain' 'send_attempt_failed' $eventId "attempt=$attempt reason=$reason"
                if ($attempt -lt $settings.SendAttemptsPerRun -and $settings.RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $settings.RetryDelaySeconds }
            }
            if ($null -eq $receipt -or -not $receipt.Success) {
                if ($null -ne $receipt) { $resultCode = 2 }
                continue
            }
            Write-CfnJsonAtomic $sentPath @{ sent_at = [datetimeoffset]::UtcNow.ToString('o'); message_id = $receipt.MessageId; event_id = $eventId }
            if (Test-Path -LiteralPath $file.FullName) { Remove-Item -LiteralPath $file.FullName -Force }
            Update-CfnDeliveryResult $IntegrationRoot 'sent' 'confirmed_receipt' $eventId $receipt.MessageId
            Write-CfnLog $IntegrationRoot 'drain' 'sent' $eventId
        } catch {
            $resultCode = 2
            if ($DryRun) { Write-Warning (Protect-CfnPreview $_.Exception.Message 300) }
            else {
                Update-CfnDeliveryResult $IntegrationRoot 'blocked' (Protect-CfnPreview $_.Exception.Message 300) $file.BaseName
                Write-CfnLog $IntegrationRoot 'drain' 'item_exception' $file.BaseName $_.Exception.Message
            }
        }
    }
    if (-not $DryRun) { Invoke-CfnRetention $IntegrationRoot $settings }
} catch {
    $resultCode = 2
    if ($DryRun) { Write-Warning (Protect-CfnPreview $_.Exception.Message 300) }
    else {
        Update-CfnDeliveryResult $IntegrationRoot 'blocked' (Protect-CfnPreview $_.Exception.Message 300)
        Write-CfnLog $IntegrationRoot 'drain' 'configuration_error' '' $_.Exception.Message
    }
} finally { Exit-CfnMutex $workerLock }
exit $resultCode
