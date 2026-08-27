param(
    [switch] $DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $IntegrationRoot 'CodexFeishuNotify.psm1') -Force -DisableNameChecking
$pendingRoot = Join-Path $IntegrationRoot 'spool\pending'
$sentRoot = Join-Path $IntegrationRoot 'spool\sent'
$expiredRoot = Join-Path $IntegrationRoot 'spool\expired'

try {
    $settings = Get-CfnSettings $IntegrationRoot
} catch {
    Write-CfnLog $IntegrationRoot 'drain' 'settings_invalid' '' $_.Exception.Message
    exit 0
}

foreach ($path in @($pendingRoot, $sentRoot, $expiredRoot)) { Ensure-CfnDirectory $path }

if (-not $DryRun) {
    try {
        $deliveryControl = Get-CfnDeliveryControlState $IntegrationRoot $settings
        if (-not $deliveryControl.EffectiveActive) {
            Write-CfnLog $IntegrationRoot 'drain' $deliveryControl.Reason '' "next=$($deliveryControl.NextScheduleStart.ToString('o'))"
            exit 0
        }
    } catch {
        # A schedule/configuration error must fail closed: never send outside a
        # window merely because its boundaries could not be evaluated.
        Write-CfnLog $IntegrationRoot 'drain' 'schedule_invalid' '' $_.Exception.Message
        exit 0
    }
}

$pendingItems = @(Get-ChildItem -LiteralPath $pendingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc)
if (-not $settings.FeishuEnabled) {
    if ($pendingItems.Count -gt 0) {
        Write-CfnLog $IntegrationRoot 'drain' 'feishu_disabled' '' "pending=$($pendingItems.Count)"
    }
    exit 0
}
if ($pendingItems.Count -gt 0) {
    if ($settings.TransportType -ne 'lark-cli') {
        Write-CfnLog $IntegrationRoot 'drain' 'unsupported_transport' '' $settings.TransportType
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($settings.ChatId) -or $settings.ChatId -match 'REPLACE') {
        Write-CfnLog $IntegrationRoot 'drain' 'chat_id_missing'
        exit 0
    }

    try {
        Initialize-CfnLarkProfile $settings
        $larkCli = Find-CfnLarkCli $settings.LarkCliPath
        if (-not $larkCli) { throw 'lark-cli was not found.' }
    } catch {
        Write-CfnLog $IntegrationRoot 'drain' 'transport_not_ready' '' $_.Exception.Message
        exit 0
    }

    foreach ($file in $pendingItems) {
        try {
            $settings = Get-CfnSettings $IntegrationRoot
            if (-not $settings.FeishuEnabled) {
                Write-CfnLog $IntegrationRoot 'drain' 'feishu_disabled_during_run' '' "remaining=$(@($pendingItems | Where-Object { $_.CreationTimeUtc -ge $file.CreationTimeUtc }).Count)"
                break
            }
            if (-not $DryRun) {
                $deliveryControl = Get-CfnDeliveryControlState $IntegrationRoot $settings
                if (-not $deliveryControl.EffectiveActive) {
                    Write-CfnLog $IntegrationRoot 'drain' $deliveryControl.Reason '' 'stopped-during-run'
                    break
                }
            }
            $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $eventId = [string](Get-CfnProperty $item 'event_id' '')
            if (-not $eventId -or $file.BaseName -ne $eventId) {
                Write-CfnLog $IntegrationRoot 'drain' 'invalid_queue_item' $file.BaseName
                continue
            }

            $createdAtText = [string](Get-CfnProperty $item 'created_at' '')
            try { $createdAt = [datetimeoffset]::Parse($createdAtText).ToUniversalTime() } catch { $createdAt = [datetimeoffset]::MinValue }
            if ($createdAt -eq [datetimeoffset]::MinValue -or
                $createdAt -lt [datetimeoffset]::UtcNow.AddHours(-$settings.MaxQueueAgeHours)) {
                Move-Item -LiteralPath $file.FullName -Destination (Join-Path $expiredRoot $file.Name) -Force
                Write-CfnLog $IntegrationRoot 'drain' 'expired' $eventId
                continue
            }

            $sentPath = Join-Path $sentRoot "$eventId.sent"
            if (Test-Path -LiteralPath $sentPath) {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-CfnLog $IntegrationRoot 'drain' 'already_sent' $eventId
                continue
            }

            $deliveryPayload = Get-CfnDeliveryPayload $item $settings
            $idempotencyKey = "cx-$eventId"
            $arguments = @('im', '+messages-send', '--as', 'bot', '--chat-id', $settings.ChatId)
            if ($deliveryPayload.MessageType -eq 'interactive') {
                $arguments += @('--msg-type', 'interactive')
            }
            $arguments += @($deliveryPayload.ContentFlag, $deliveryPayload.Content, '--idempotency-key', $idempotencyKey, '--format', 'json')
            if ($DryRun) { $arguments += '--dry-run' }

            $sendResult = $null
            $output = ''
            $attemptLimit = if ($DryRun) { 1 } else { $settings.SendAttemptsPerRun }
            for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
                $previousPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $output = (& $larkCli @arguments 2>&1 | Out-String)
                    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
                } finally {
                    $ErrorActionPreference = $previousPreference
                }
                $sendResult = Test-CfnTransportOutput $exitCode $output
                if ($sendResult.Success) { break }
                Write-CfnLog $IntegrationRoot 'drain' 'send_attempt_failed' $eventId "attempt=$attempt reason=$($sendResult.Reason) $output"
                if ($attempt -lt $attemptLimit -and $settings.RetryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $settings.RetryDelaySeconds
                }
            }

            if ($null -eq $sendResult -or -not $sendResult.Success) {
                $reason = if ($null -eq $sendResult) { 'no_result' } else { $sendResult.Reason }
                Write-CfnLog $IntegrationRoot 'drain' 'send_failed' $eventId $reason
                continue
            }
            if ($DryRun) {
                Write-CfnLog $IntegrationRoot 'drain' 'dry_run_ok' $eventId
                continue
            }

            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($sentPath, (Get-Date).ToUniversalTime().ToString('o'), $utf8NoBom)
            Remove-Item -LiteralPath $file.FullName -Force
            Write-CfnLog $IntegrationRoot 'drain' 'sent' $eventId
        } catch {
            Write-CfnLog $IntegrationRoot 'drain' 'item_exception' $file.BaseName $_.Exception.Message
        }
    }
}

$sentCutoff = (Get-Date).ToUniversalTime().AddDays(-$settings.SentMarkerRetentionDays)
Get-ChildItem -LiteralPath $sentRoot -Filter '*.sent' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -lt $sentCutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$expiredCutoff = (Get-Date).ToUniversalTime().AddDays(-$settings.ExpiredItemRetentionDays)
Get-ChildItem -LiteralPath $expiredRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -lt $expiredCutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue

exit 0
