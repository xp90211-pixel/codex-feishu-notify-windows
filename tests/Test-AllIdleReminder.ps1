$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'src\CfnIdleReminder.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'NotificationTestSupport.ps1')
$stage = Join-Path ([IO.Path]::GetTempPath()) ('cfn-notification-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-CfnOfflineRuntime $projectRoot $stage
    $assertions = 0
    function Assert-Idle([bool] $Condition, [string] $Message) {
        if (-not $Condition) { throw $Message }
        $script:assertions++
    }
    function Snapshot([int] $Running, [int] $Waiting = 0, [bool] $Known = $true) {
        return [pscustomobject]@{ Known = $Known; Running = $Running; Waiting = $Waiting; Stopped = 5 }
    }
    $raw = Get-Content -LiteralPath (Join-Path $projectRoot 'config\settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $raw.delivery.holiday_region = 'None'
    $raw.desktop.enabled = $false
    Write-CfnJsonAtomic (Join-Path $stage 'settings.local.json') $raw
    $settings = Get-CfnSettings $stage
    $start = [datetime]'2026-09-21T18:40:00'
    $window = Get-CfnIdleWindow $settings $start
    Assert-Idle ($window.End -eq [datetime]'2026-09-22T02:00:00') 'Overnight window end is wrong.'
    Assert-Idle ((Get-CfnIdleWindow $settings ([datetime]'2026-09-22T01:30:00')).Key -ceq $window.Key) 'Midnight changed the window identity.'
    Assert-Idle ($null -eq (Get-CfnIdleWindow $settings ([datetime]'2026-09-22T02:00:00'))) 'End boundary is not exclusive.'
    $state = (Update-CfnIdleState $null $window (Snapshot 3) $start).State
    Assert-Idle ($state.phase -eq 'armed' -and $state.initial_running -eq 3) 'Start-time running tasks did not arm the reminder.'
    $step = Update-CfnIdleState $state $window (Snapshot 1 2) $start.AddMinutes(1)
    Assert-Idle (-not $step.Notify -and -not $step.State.idle_since) 'Partial completion fired a reminder.'
    $step = Update-CfnIdleState $state $window (Snapshot 0 3) $start.AddMinutes(2)
    Assert-Idle (-not $step.Notify -and $step.State.idle_since) 'Idle transition was not debounced.'
    $step = Update-CfnIdleState $state $window (Snapshot 0 3) $start.AddMinutes(2).AddSeconds(5)
    Assert-Idle $step.Notify 'All waiting tasks should qualify after confirmation.'
    $state.phase = 'notified'
    Assert-Idle (-not (Update-CfnIdleState $state $window (Snapshot 0 3) $start.AddMinutes(3)).Notify) 'Repeated checks produced duplicates.'
    $skipped = (Update-CfnIdleState $null $window (Snapshot 0 2) $start).State
    Assert-Idle ($skipped.phase -eq 'skipped') 'An initially idle window should not arm.'
    Assert-Idle ((Update-CfnIdleState $skipped $window (Snapshot 2) $start.AddMinutes(1)).State.phase -eq 'skipped') 'A later task incorrectly armed an initially idle window.'
    $late = Update-CfnIdleState $null $window (Snapshot 1) $start.AddMinutes(3)
    Assert-Idle ($late.State.phase -eq 'skipped') 'A late baseline fabricated start-time activity.'
    $unknown = (Update-CfnIdleState $null $window (Snapshot 0 0 $false) $start).State
    Assert-Idle ($unknown.phase -eq 'baseline') 'Unknown status became idle.'
    Assert-Idle ((Update-CfnIdleState $unknown $window (Snapshot 0 0 $false) $start.AddMinutes(3)).State.phase -eq 'skipped') 'Unknown baseline never expired.'
    $state = (Update-CfnIdleState $null $window (Snapshot 2) $start).State
    $state = (Update-CfnIdleState $state $window (Snapshot 0) $start.AddMinutes(1)).State
    $step = Update-CfnIdleState $state $window (Snapshot 1) $start.AddMinutes(1).AddSeconds(3)
    Assert-Idle (-not $step.Notify -and -not $step.State.idle_since) 'A new running task did not cancel confirmation.'
    $state = (Update-CfnIdleState $state $window (Snapshot 0) $start.AddMinutes(2)).State
    $step = Update-CfnIdleState $state $window (Snapshot 0 0 $false) $start.AddMinutes(2).AddSeconds(5)
    Assert-Idle (-not $step.Notify -and -not $step.State.idle_since) 'Failed reads were treated as stopped tasks.'
    $next = Get-CfnIdleWindow $settings $start.AddDays(1)
    Assert-Idle ((Update-CfnIdleState $skipped $next (Snapshot 1) $start.AddDays(1)).State.phase -eq 'armed') 'The next window did not reset.'
    foreach ($type in @('idle', 'notLoaded', 'systemError')) {
        Assert-Idle ((ConvertTo-CfnIdleStatus ([pscustomobject]@{type=$type})) -eq 'stopped') "Wrong stopped mapping: $type"
    }
    Assert-Idle ((ConvertTo-CfnIdleStatus ([pscustomobject]@{type='active';activeFlags=@()})) -eq 'running') 'Active without flags is not running.'
    foreach ($flag in @('waitingOnApproval','waitingOnUserInput')) {
        Assert-Idle ((ConvertTo-CfnIdleStatus ([pscustomobject]@{type='active';activeFlags=@($flag)})) -eq 'waiting') "Wrong waiting mapping: $flag"
    }
    Assert-Idle ((ConvertTo-CfnIdleStatus ([pscustomobject]@{type='active';activeFlags=@('futureFlag')})) -eq 'unknown') 'An unknown active flag was treated as idle.'
    Assert-Idle ((ConvertTo-CfnIdleStatus 'active') -eq 'unknown') 'Flattened status lost its active flags.'

    # Exercise the inventory adapter without opening an application pipe. A loaded
    # task outside the recent-50 list must still prevent an "all stopped" claim.
    $inventoryRoot = Join-Path $stage 'inventory'
    $lockedThread = '11111111-1111-4111-8111-111111111111'
    Write-CfnJsonAtomic (Join-Path $inventoryRoot "thread-writer-locks\$lockedThread.lock") @{}
    Write-CfnJsonAtomic (Join-Path $stage 'spool\state\idle-app-endpoint.json') @{ pipe = 'fixture'; thread_id = $lockedThread }
    $module = Get-Module CfnIdleReminder
    & $module {
        param($FixtureRoot)
        $script:InventoryRoot = $FixtureRoot
        $script:InventoryMode = 'known'
        function script:Get-CfnCodexHome { param($IntegrationRoot) return $script:InventoryRoot }
        function script:Invoke-CfnIdleStatusTool {
            param($Endpoint, $Tool, $Arguments)
            if ($Tool -eq 'list_threads') {
                return [pscustomobject]@{
                    pinnedThreads = @([pscustomobject]@{ id = 'pinned'; kind = 'codex'; hostId = 'local'; status = 'active' })
                    threads = @([pscustomobject]@{ id = 'remote'; kind = 'codex'; hostId = 'remote'; status = 'active' })
                    unavailableSources = $(if ($script:InventoryMode -eq 'incomplete') { @('fixture') } else { @() })
                }
            }
            if ($script:InventoryMode -eq 'changed') {
                Write-CfnJsonAtomic (Join-Path $script:InventoryRoot 'thread-writer-locks\22222222-2222-4222-8222-222222222222.lock') @{}
            }
            $flags = @()
            if ($script:InventoryMode -eq 'unknown') { $flags = @('futureFlag') }
            elseif ($Arguments.threadId -eq 'pinned') { $flags = @('waitingOnUserInput') }
            return [pscustomobject]@{ thread = [pscustomobject]@{ status = [pscustomobject]@{ type = 'active'; activeFlags = @($flags) } } }
        }
    } $inventoryRoot
    $inventory = Get-CfnIdleSnapshot $stage
    Assert-Idle ($inventory.Known -and $inventory.Running -eq 1 -and $inventory.Waiting -eq 1) 'Loaded tasks outside the list or local waiting flags were lost.'
    foreach ($mode in @('incomplete', 'unknown', 'changed')) {
        & $module { param($Mode) $script:InventoryMode = $Mode } $mode
        $failedClosed = $false
        try { Get-CfnIdleSnapshot $stage | Out-Null } catch { $failedClosed = $true }
        Assert-Idle $failedClosed "Inventory mode $mode did not fail closed."
    }
    # Reload the public module so the inventory mocks cannot affect later checks.
    Import-Module (Join-Path $projectRoot 'src\CfnIdleReminder.psm1') -Force -DisableNameChecking

    $raw.delivery.holiday_region = 'None'
    $raw.delivery.all_day_weekdays = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    $raw.transport.require_profile = $false
    $raw.transport.chat_id = 'oc_TESTCONFIG1234'
    $raw.transport.cli_path = Join-Path $stage 'fake-lark.exe'
    $raw.transport.send_attempts_per_run = 1
    $raw.transport.retry_delay_seconds = 0
    $raw.delivery | Add-Member NoteProperty fresh_notifications_only $true -Force
    Write-CfnJsonAtomic (Join-Path $stage 'settings.local.json') $raw
    Write-CfnJsonAtomic (Join-Path $stage 'idle-reminder.settings.json') @{ schema=1;enabled=$true;channel='feishu';confirm_seconds=1 }
    $stageSettings = Get-CfnSettings $stage
    $stageWindow = Get-CfnIdleWindow $stageSettings
    $state = (Update-CfnIdleState $null $stageWindow (Snapshot 2) $stageWindow.Start).State
    Write-CfnJsonAtomic (Join-Path $stage 'spool\state\idle-window.json') $state
    $module = Get-Module CfnIdleReminder
    & $module {
        function script:Get-CfnIdleSnapshot {
            param([string] $IntegrationRoot)
            return [pscustomobject]@{ Known=$true;Running=0;Waiting=2;Stopped=5 }
        }
    }
    Invoke-CfnIdleReminder $stage $stageSettings (Get-CfnDeliveryControlState $stage $stageSettings)
    $queued = @(Get-ChildItem -LiteralPath (Join-Path $stage 'spool\pending') -Filter '*.json')
    Assert-Idle ($queued.Count -eq 1) 'The all-idle transition did not queue exactly one notification.'
    $item = Get-Content -LiteralPath $queued[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Idle ($item.kind -eq 'all-idle' -and $item.result_preview -match '2 项') 'Summary kind or waiting count is wrong.'
    Invoke-CfnIdleReminder $stage $stageSettings (Get-CfnDeliveryControlState $stage $stageSettings)
    Assert-Idle (@(Get-ChildItem -LiteralPath (Join-Path $stage 'spool\pending') -Filter '*.json').Count -eq 1) 'A second poll queued a duplicate.'
    $payload = Get-CfnIdleDeliveryPayload $item $stageSettings
    $card = $payload.Content | ConvertFrom-Json
    Assert-Idle ($card.header.title.content -eq 'Codex 当前没有运行中的任务' -and $card.header.template -eq 'blue') 'Summary card is wrong.'
    $stageSettings.MessageFormat = 'text'
    Assert-Idle ((Get-CfnIdleDeliveryPayload $item $stageSettings).ContentFlag -eq '--text') 'Text mode is unsupported.'

    # Exercise the real drainer with an offline CLI fixture, including an ordinary
    # pre-existing completion. No network transport is possible in this fixture.
    Write-CfnJsonAtomic (Join-Path $stage 'idle-reminder.settings.json') @{ schema=1;enabled=$false;channel='feishu';confirm_seconds=1 }
    $existingId = Get-CfnEventId 'ordinary-completion-regression'
    $ordinaryItem = @{ schema=2;event_id=$existingId;kind='completed';created_at=[datetimeoffset]::UtcNow.ToString('o');project='fixture';task_preview='';result_preview='existing notification' }
    if (-not (Set-CfnQueueDeliveryWindow $stage (Get-CfnSettings $stage) $ordinaryItem)) { throw 'Ordinary fixture did not enter its window.' }
    Write-CfnJsonAtomic (Join-Path $stage "spool\pending\$existingId.json") $ordinaryItem
    $savedControl = $env:CFN_TEST_CONTROL
    $env:CFN_TEST_CONTROL = $stage
    Write-CfnJsonAtomic (Join-Path $stage 'mode.txt') 'success'
    try {
        $before = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join '|'
        [void](Invoke-CfnFixtureProcess (Join-Path $stage 'notification-host.exe') @('drain','-DryRun'))
        $after = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join '|'
        Assert-Idle ($before -ceq $after) 'DryRun modified state or invoked the CLI.'
        [void](Invoke-CfnFixtureProcess (Join-Path $stage 'notification-host.exe') @('drain'))
        Assert-Idle (@(Get-ChildItem -LiteralPath $stage -Filter 'call-*.txt').Count -eq 2) 'Summary and ordinary notifications did not reach the offline transport.'
        Assert-Idle (@(Get-ChildItem -LiteralPath (Join-Path $stage 'spool\sent') -Filter '*.sent').Count -eq 2) 'Confirmed delivery markers are missing.'
        $titles = @(Get-ChildItem -LiteralPath $stage -Filter 'call-*.txt' | ForEach-Object {
            $argv = @(Get-Content -LiteralPath $_.FullName -Encoding UTF8 | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
            $contentIndex = [array]::IndexOf($argv, '--content')
            Assert-Idle ($contentIndex -ge 0) 'Card content flag was lost.'
            ($argv[$contentIndex + 1] | ConvertFrom-Json).header.title.content
        })
        Assert-Idle ($titles -contains 'Codex 当前没有运行中的任务' -and $titles -contains 'Codex 本轮回复完成') 'Summary or existing card text was damaged in transit.'
        [void](Invoke-CfnFixtureProcess (Join-Path $stage 'notification-host.exe') @('drain'))
        Assert-Idle (@(Get-ChildItem -LiteralPath $stage -Filter 'call-*.txt').Count -eq 2) 'Transport duplicated a summary.'
        $expiredId = Get-CfnEventId 'expired-summary-regression'
        $item.event_id = $expiredId
        $item.window_end = (Get-Date).AddMinutes(-1).ToString('o')
        Write-CfnJsonAtomic (Join-Path $stage "spool\pending\$expiredId.json") $item
        [void](Invoke-CfnFixtureProcess (Join-Path $stage 'notification-host.exe') @('drain'))
        Assert-Idle (@(Get-ChildItem -LiteralPath $stage -Filter 'call-*.txt').Count -eq 2) 'An old summary was sent after its window ended.'
        Assert-Idle (Test-Path -LiteralPath (Join-Path $stage "spool\expired\$expiredId.json")) 'Expired summary was not retained in the expiry queue.'
    } finally { $env:CFN_TEST_CONTROL = $savedControl }
    @{ assertions=$assertions; actualMessagesSent=0; fixtureRoot=$stage } | ConvertTo-Json -Compress
} finally { Remove-CfnOfflineRuntime $stage }
