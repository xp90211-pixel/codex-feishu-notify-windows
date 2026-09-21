$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'NotificationTestSupport.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('cfn-notification-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-CfnOfflineRuntime $projectRoot $root
    $count = 0
    function Assert-Fresh([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
    function Item([string] $Key, [datetime] $At, [string] $ThreadId = '', [string] $TurnId = '') {
        return [pscustomobject]@{ schema=2;kind='completed';event_id=(Get-CfnEventId $Key);created_at=([datetimeoffset]$At).ToUniversalTime().ToString('o');thread_id=$ThreadId;turn_id=$TurnId;project='fixture';task_preview='';result_preview='本轮结果' }
    }
    $raw = Get-Content -LiteralPath (Join-Path $projectRoot 'config\settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $raw.desktop.enabled = $false
    $raw.delivery | Add-Member NoteProperty fresh_notifications_only $true -Force
    $raw.delivery.holiday_region = 'None'; $raw.delivery.all_day_weekdays = @()
    $raw.transport.require_profile = $false; $raw.transport.chat_id = 'oc_TESTCONFIG1234'
    $raw.transport.cli_path = Join-Path $root 'fake-lark.exe'; $raw.transport.send_attempts_per_run=1; $raw.transport.retry_delay_seconds=0
    $raw.filters.visible_threads_only=$false; $raw.filters.skip_bridge_origin=$false; $raw.lifecycle.strict_completion_gate=$false
    Write-CfnJsonAtomic (Join-Path $root 'settings.local.json') $raw
    Write-CfnJsonAtomic (Join-Path $root 'idle-reminder.settings.json') @{ schema=1;enabled=$false;channel='feishu';confirm_seconds=1 }
    $settings = Get-CfnSettings $root
    $begin = [datetime]'2026-09-21T18:40:00'
    $before = Item 'before-start' $begin.AddSeconds(-1)
    Assert-Fresh (-not (Set-CfnQueueDeliveryWindow $root $settings $before $begin.AddSeconds(-1))) 'An outside-window event entered the queue.'
    $current = Item 'current-start' $begin
    Assert-Fresh (Set-CfnQueueDeliveryWindow $root $settings $current $begin) 'The inclusive start boundary was rejected.'
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $current $begin.AddHours(1)) -eq 'eligible') 'A current-window event was rejected.'
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $current ([datetime]'2026-09-22T01:00:00')) -eq 'eligible') 'Midnight expired a current-window event.'
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $current ([datetime]'2026-09-22T02:00:00')) -eq 'outside_delivery_window') 'End boundary was not exclusive.'
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $current $begin.AddDays(1)) -eq 'historical_window') 'Previous-window history was eligible.'
    $legacy = Item 'unstamped' $begin
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $legacy $begin.AddMinutes(1)) -eq 'legacy_unstamped') 'Legacy backlog was accepted as current progress.'
    $future = Item 'future' $begin.AddMinutes(2)
    Assert-Fresh (-not (Set-CfnQueueDeliveryWindow $root $settings $future $begin)) 'A future timestamp entered the queue.'
    [void](Set-CfnManualDeliveryState $root 'force' ([datetimeoffset]([datetime]'2026-09-21T11:00:00')) ([datetimeoffset]([datetime]'2026-09-21T10:00:00')))
    $manualItem = Item 'new-manual-event' ([datetime]'2026-09-21T10:10:00')
    Assert-Fresh (Set-CfnQueueDeliveryWindow $root $settings $manualItem ([datetime]'2026-09-21T10:10:00')) 'A newly forced delivery window was rejected.'
    $oldManualItem = Item 'before-manual-force' ([datetime]'2026-09-21T09:59:00')
    Assert-Fresh (-not (Set-CfnQueueDeliveryWindow $root $settings $oldManualItem ([datetime]'2026-09-21T10:10:00'))) 'Manual force replayed earlier history.'
    Clear-CfnManualDeliveryState $root
    $settings.FreshNotificationsOnly=$false
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $legacy $begin.AddDays(1)) -eq 'eligible') 'Legacy mode compatibility was changed.'

    $pwsh=(Get-Process -Id $PID).Path
    $thread=[guid]::NewGuid().ToString();$turnA=[guid]::NewGuid().ToString();$turnB=[guid]::NewGuid().ToString();$turnC=[guid]::NewGuid().ToString()
    function Notify([string] $Turn) {
        $json=@{type='agent-turn-complete';'thread-id'=$thread;'turn-id'=$Turn;cwd=$root;'input-messages'=@('fixture');'last-assistant-message'='最新结果'} | ConvertTo-Json -Compress
        [void](Invoke-CfnFixtureProcess (Join-Path $root 'notification-host.exe') @('notify',$json))
    }
    function Hook([string] $Name,[string] $Turn) {
        $json=@{hook_event_name=$Name;session_id=$thread;turn_id=$Turn;cwd=$root;tool_name='fixture';tool_input=@{x=1};request_id='req-fixture'} | ConvertTo-Json -Depth 5 -Compress
        $json64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $hookPath = (Join-Path $root 'hook.ps1').Replace("'", "''")
        $command = "[Console]::SetIn([IO.StringReader]::new([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$json64')))); & '$hookPath'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        [void](Invoke-CfnFixtureProcess $pwsh @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded))
    }
    function Pending { return @(Get-ChildItem -LiteralPath (Join-Path $root 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue) }
    # Choose an inactive interval relative to the wall clock, avoiding a clock override.
    $raw.delivery.start=(Get-Date).AddHours(1).ToString('HH:mm');$raw.delivery.end=(Get-Date).AddHours(2).ToString('HH:mm')
    Write-CfnJsonAtomic (Join-Path $root 'settings.local.json') $raw
    Notify $turnA
    Assert-Fresh (@(Pending).Count -eq 0) 'An out-of-hours completion was queued.'
    Hook 'PermissionRequest' $turnA
    Assert-Fresh (@(Pending).Count -eq 0) 'An out-of-hours permission notification was queued.'
    # Current-window events are permitted; a new turn cancels the previous result.
    $raw.delivery.all_day_weekdays=@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    Write-CfnJsonAtomic (Join-Path $root 'settings.local.json') $raw
    Notify $turnA
    Assert-Fresh (@(Pending).Count -eq 1) 'An in-window completion was not queued.'
    $inFlight=Get-Content -LiteralPath (Pending)[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Hook 'UserPromptSubmit' $turnB
    Assert-Fresh (@(Pending).Count -eq 0) 'Starting a new turn did not suppress the old completion.'
    Assert-Fresh (@(Get-ChildItem -LiteralPath (Join-Path $root 'spool\suppressed') -Filter '*.json').Count -eq 1) 'Superseded content is not recoverable.'
    Notify $turnA
    Assert-Fresh (@(Pending).Count -eq 0) 'A delayed completion from the previous turn was accepted.'
    Notify $turnB
    Assert-Fresh (@(Pending).Count -eq 1) 'New-turn completion did not replace old progress.'
    Notify $turnC
    Assert-Fresh (@(Pending).Count -eq 1) 'Multiple unsent completions for one thread accumulated.'
    $settings=Get-CfnSettings $root
    Assert-Fresh ((Get-CfnQueueFreshness $root $settings $inFlight) -eq 'superseded_by_new_activity') 'In-memory stale send survived a new turn.'

    $savedControl=$env:CFN_TEST_CONTROL;$env:CFN_TEST_CONTROL=$root
    Write-CfnJsonAtomic (Join-Path $root 'mode.txt') 'success'
    try {
        $blocked=Invoke-CfnTransport $root $raw.transport.cli_path @('fake') $settings $inFlight
        Assert-Fresh $blocked.Skipped 'Final transport preflight submitted obsolete progress.'
        Assert-Fresh (@(Get-ChildItem -LiteralPath $root -Filter 'call-*.txt').Count -eq 0) 'The fake CLI received a stale send.'
        $old=Item 'old-backlog' (Get-Date).AddDays(-1)
        Write-CfnJsonAtomic (Join-Path $root ("spool\pending\"+$old.event_id+'.json')) $old
        $unstamped=Item 'legacy-backlog' (Get-Date)
        Write-CfnJsonAtomic (Join-Path $root ("spool\pending\"+$unstamped.event_id+'.json')) $unstamped
        $beforeFiles=@(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash}) -join '|'
        [void](Invoke-CfnFixtureProcess (Join-Path $root 'notification-host.exe') @('drain','-DryRun'))
        $afterFiles=@(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash}) -join '|'
        Assert-Fresh ($beforeFiles -ceq $afterFiles) 'DryRun modified the queue or state.'
        [void](Invoke-CfnFixtureProcess (Join-Path $root 'notification-host.exe') @('drain'))
        Assert-Fresh (@(Get-ChildItem -LiteralPath $root -Filter 'call-*.txt').Count -eq 1) 'The worker did not send exactly the newest eligible completion.'
        Assert-Fresh (@(Pending).Count -eq 0) 'The worker left historical backlog in pending.'
        [void](Invoke-CfnFixtureProcess (Join-Path $root 'notification-host.exe') @('drain'))
        Assert-Fresh (@(Get-ChildItem -LiteralPath $root -Filter 'call-*.txt').Count -eq 1) 'A later poll replayed an event.'
        $card=New-CfnCardContent (Item 'label' (Get-Date)) $settings | ConvertFrom-Json
        Assert-Fresh ($card.header.title.content -eq 'Codex 本轮回复完成') 'Completion label still implies entire project completion.'
        Assert-Fresh ($card.elements[1].elements[0].content -like '事件时间：*') 'The timestamp is not identified as event time.'
    } finally { $env:CFN_TEST_CONTROL=$savedControl }
    @{assertions=$count;actualMessagesSent=0;fixtureRoot=$root} | ConvertTo-Json -Compress
} finally { Remove-CfnOfflineRuntime $root }
