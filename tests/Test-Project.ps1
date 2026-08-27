[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $failures.Add($Message) }
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $syntaxDetail = if ($errors.Count -gt 0) { (@($errors | ForEach-Object { $_.Message }) -join '; ') } else { '' }
    Assert-True ($errors.Count -eq 0) "PowerShell syntax failed: $($file.FullName) $syntaxDetail"
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasUtf8Bom) { 3 } else { 0 }
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    if ([regex]::IsMatch($decoded, '[^\x00-\x7F]')) {
        Assert-True $hasUtf8Bom "PowerShell files containing non-ASCII text must use a UTF-8 BOM for Windows PowerShell 5.1: $($file.FullName)"
    }
}

$modulePath = Join-Path $projectRoot 'src\CodexFeishuNotify.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$window = Get-CfnScheduleWindow '18:40' '02:00'
Assert-True ($window.Duration.TotalMinutes -eq 440) '18:40-02:00 must be 440 minutes.'
Assert-True ($window.IsoDuration -eq 'PT7H20M') '18:40-02:00 must serialize as PT7H20M.'

$sgCalendarPath = Join-Path $projectRoot 'config\holidays.sg.json'
$sgCalendar = Get-CfnHolidayCalendar $sgCalendarPath
Assert-True ($sgCalendar.Region -eq 'SG') 'The Singapore calendar must declare region SG.'
Assert-True ($sgCalendar.Holidays.Count -eq 26) 'The Singapore calendar must contain the published 2026-2027 dates.'
Assert-True (@($sgCalendar.Holidays | Where-Object { $_.DateText -eq '2026-11-09' -and $_.Observed }).Count -eq 1) 'The observed 2026 Deepavali holiday must be included.'
Assert-True (@($sgCalendar.Holidays | Where-Object { $_.DateText -eq '2027-02-08' -and $_.Observed }).Count -eq 1) 'The observed 2027 Chinese New Year holiday must be included.'

$cnCalendarPath = Join-Path $projectRoot 'config\holidays.cn.2026.json'
$cnCalendar = Get-CfnHolidayCalendar $cnCalendarPath
Assert-True ($cnCalendar.Region -eq 'CN') 'The China calendar must declare region CN.'
Assert-True ($cnCalendar.Holidays.Count -eq 33) 'The China calendar must contain all official 2026 days off.'
Assert-True ($cnCalendar.Workdays.Count -eq 6) 'The China calendar must record all 2026 adjusted working days.'

$holidayGaps = @(Get-CfnHolidayGapWindows ([datetime]'2026-11-09') '18:40' '02:00')
Assert-True ($holidayGaps.Count -eq 1) 'A cross-midnight schedule must leave one holiday gap.'
Assert-True ($holidayGaps[0].Start.ToString('yyyy-MM-dd HH:mm') -eq '2026-11-09 02:00') 'The holiday gap must start when the overnight window ends.'
Assert-True ($holidayGaps[0].End.ToString('yyyy-MM-dd HH:mm') -eq '2026-11-09 18:40') 'The holiday gap must end when the daily window starts.'
Assert-True ($holidayGaps[0].Duration.TotalMinutes -eq 1000 -and $holidayGaps[0].IsoDuration -eq 'PT16H40M') 'The holiday gap must serialize as PT16H40M.'

$daytimeGaps = @(Get-CfnHolidayGapWindows ([datetime]'2026-11-09') '09:00' '17:00')
Assert-True ($daytimeGaps.Count -eq 2) 'A same-day schedule must leave two holiday gaps.'
Assert-True ($daytimeGaps[0].IsoDuration -eq 'PT9H' -and $daytimeGaps[1].IsoDuration -eq 'PT7H') 'Same-day holiday gaps must cover the rest of the calendar day.'

if ($env:OS -eq 'Windows_NT') {
    $testTrigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add($window.StartTime))
    $testRepetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
        Interval = 'PT1M'
        Duration = $window.IsoDuration
        StopAtDurationEnd = $true
    }
    $testTrigger.Repetition = $testRepetition
    Assert-True ($testTrigger.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger') 'The installer trigger must be a true daily trigger.'
    Assert-True ($testTrigger.DaysInterval -eq 1) 'The daily trigger must recur every day.'
    Assert-True ($testTrigger.Repetition.Interval -eq 'PT1M' -and $testTrigger.Repetition.Duration -eq 'PT7H20M') 'The trigger repetition must cover the configured window.'

    $testHolidayTrigger = New-ScheduledTaskTrigger -Once -At $holidayGaps[0].Start
    $testHolidayRepetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
        Interval = 'PT1M'
        Duration = $holidayGaps[0].IsoDuration
        StopAtDurationEnd = $true
    }
    $testHolidayTrigger.Repetition = $testHolidayRepetition
    Assert-True ($testHolidayTrigger.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger') 'Holiday extensions must use one-time date-specific triggers.'
    Assert-True ($testHolidayTrigger.Repetition.Interval -eq 'PT1M' -and $testHolidayTrigger.Repetition.Duration -eq 'PT16H40M') 'A holiday trigger must cover only the missing daytime gap.'

    $testWeeklyTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Saturday,Sunday -At $holidayGaps[0].Start
    $testWeeklyRepetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
        Interval = 'PT1M'
        Duration = $holidayGaps[0].IsoDuration
        StopAtDurationEnd = $true
    }
    $testWeeklyTrigger.Repetition = $testWeeklyRepetition
    Assert-True ($testWeeklyTrigger.CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger' -and $testWeeklyTrigger.WeeksInterval -eq 1) 'Selected all-day weekdays must use a true weekly trigger.'
    Assert-True ([int]$testWeeklyTrigger.DaysOfWeek -eq 65 -and $testWeeklyTrigger.Repetition.Duration -eq 'PT16H40M') 'The weekly trigger must combine selected weekdays and cover only the missing daytime gap.'

    $testTaskSettings = New-ScheduledTaskSettingsSet -Hidden -DisallowDemandStart -StartWhenAvailable:$false
    Assert-True (-not $testTaskSettings.AllowDemandStart) 'Demand start must be disabled.'
    Assert-True (-not $testTaskSettings.StartWhenAvailable) 'Missed runs must not start outside the configured window.'
}

$eventId1 = Get-CfnEventId 'thread|turn'
$eventId2 = Get-CfnEventId 'thread|turn'
Assert-True ($eventId1 -eq $eventId2) 'Event ids must be deterministic.'
Assert-True ($eventId1 -match '^[0-9a-f]{40}$') 'Event id must be a 40-character lowercase hex digest prefix.'

$toastXmlText = New-CfnToastXml -Title 'Codex <done>' -Body 'Result & details' -Persistent
try { $toastXml = [xml]$toastXmlText } catch { $toastXml = $null }
Assert-True ($null -ne $toastXml -and $toastXml.toast.scenario -eq 'reminder') 'Persistent Windows toast XML must be valid and use reminder mode.'
Assert-True ($toastXmlText -match '&lt;done&gt;' -and $toastXmlText -match 'Result &amp; details') 'Toast text must be XML escaped.'

$transportOk = Test-CfnTransportOutput 0 '{"code":0,"data":{"message_id":"om_test"}}'
$transportRejected = Test-CfnTransportOutput 0 '{"code":999,"msg":"rejected"}'
$transportExitFailure = Test-CfnTransportOutput 2 'failed'
Assert-True $transportOk.Success 'A zero-code JSON transport result must succeed.'
Assert-True (-not $transportRejected.Success) 'A non-zero provider code must fail even when the process exits zero.'
Assert-True (-not $transportExitFailure.Success) 'A non-zero process exit must fail.'

$sampleQueueItem = [pscustomobject]@{
    kind = 'completed'
    project = 'sample'
    task_preview = 'Run tests'
    result_preview = 'All passed'
    permission_tool = ''
    created_at = [datetimeoffset]::UtcNow.ToString('o')
}
$sampleSettings = [pscustomobject]@{
    MessageFormat = 'card'
    IncludeTaskPreview = $true
    IncludeResultPreview = $true
    IncludePermissionTool = $false
}
$cardPayload = Get-CfnDeliveryPayload $sampleQueueItem $sampleSettings
$cardObject = $cardPayload.Content | ConvertFrom-Json
Assert-True ($cardPayload.MessageType -eq 'interactive' -and $cardPayload.ContentFlag -eq '--content') 'Card mode must map to interactive content delivery.'
Assert-True ($cardObject.header.title.content -eq 'Codex 任务完成') 'Completion cards must use the expected fixed title.'

$fakeKey = 'sk-' + ('x' * 24)
$preview = Protect-CfnPreview "token=abc123456789 $fakeKey Bearer abc.def.ghi" 500
Assert-True ($preview -notmatch 'abc123456789') 'Named tokens must be redacted.'
Assert-True ($preview -notmatch [regex]::Escape($fakeKey)) 'OpenAI-style keys must be redacted.'
Assert-True ($preview -notmatch 'abc\.def\.ghi') 'Bearer tokens must be redacted.'

Assert-True (Test-CfnInternalPrompt 'You write the one-line activity update displayed beneath an existing Codex task title.') 'Known activity-update prompts must be filtered.'
Assert-True (-not (Test-CfnInternalPrompt 'Please update my README.')) 'Normal user prompts must not be treated as internal.'

$tempState = Join-Path ([System.IO.Path]::GetTempPath()) ("cfn-state-$PID.json")
try {
    [System.IO.File]::WriteAllText($tempState, '{"thread-reference-capability:thread-123":true}', (New-Object System.Text.UTF8Encoding($false)))
    Assert-True (Test-CfnVisibleThread 'thread-123' $tempState) 'Visible-thread marker must be detected.'
    Assert-True (-not (Test-CfnVisibleThread 'thread-456' $tempState)) 'Unknown thread must not be detected.'
} finally {
    Remove-Item -LiteralPath $tempState -Force -ErrorAction SilentlyContinue
}

$examplePath = Join-Path $projectRoot 'config\settings.example.json'
$example = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($example.transport.chat_id -eq 'oc_REPLACE_ME') 'The tracked settings file must contain only a placeholder chat id.'
Assert-True $example.transport.enabled 'Feishu notifications must default to enabled for backward compatibility.'
Assert-True ($example.delivery.start -eq '18:40' -and $example.delivery.end -eq '02:00') 'The example schedule must preserve the requested window.'
Assert-True ($example.delivery.holiday_region -eq 'SG' -and $example.delivery.holiday_calendar -eq 'holidays.local.json') 'The example must enable the local Singapore holiday calendar.'
Assert-True (@($example.delivery.all_day_weekdays).Count -eq 0) 'Fixed all-day weekdays must remain opt-in by default.'
Assert-True ($example.schema -eq 2 -and $example.lifecycle.strict_completion_gate) 'The example must enable the version 2 strict completion gate.'
Assert-True ($example.desktop.enabled -and $example.desktop.only_when_codex_background) 'Desktop notifications must default to background-only.'
Assert-True ($example.message.format -eq 'card' -and -not $example.message.include_permission_tool) 'Feishu cards must default to privacy-preserving permission text.'

$guiModulePath = Join-Path $projectRoot 'src\CodexFeishuNotify.Gui.psm1'
Import-Module $guiModulePath -Force -DisableNameChecking
$profileTestHome = Join-Path ([System.IO.Path]::GetTempPath()) "cfn-profile-test-$PID"
try {
    New-Item -ItemType Directory -Path (Join-Path $profileTestHome 'profiles\codex') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $profileTestHome 'profiles\staging') -Force | Out-Null
    $profileNames = @(Get-CfnGuiLarkProfiles $profileTestHome)
    Assert-True ($profileNames.Count -eq 2 -and $profileNames[0] -eq 'codex' -and $profileNames[1] -eq 'staging') 'The GUI must enumerate existing Lark profile directories in a stable order.'
} finally {
    Remove-Item -LiteralPath $profileTestHome -Recurse -Force -ErrorAction SilentlyContinue
}
$guiModel = [pscustomobject]@{
    InstallRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'cfn-gui-test'
    TaskName = 'Codex.GuiTest'
    Source = 'test'
    ChatId = 'oc_TESTCONFIG1234'
    LarkCliPath = (Get-Process -Id $PID).Path
    LarkChannelHome = Join-Path ([System.IO.Path]::GetTempPath()) 'lark-channel-test'
    LarkChannelProfile = 'codex'
    RequireLarkProfile = $false
    FeishuEnabled = $true
    ScheduleEnabled = $true
    SendAttemptsPerRun = 2
    RetryDelaySeconds = 2
    VisibleThreadsOnly = $true
    SkipBridgeOrigin = $true
    StrictCompletionGate = $true
    NotifyPermissionRequests = $true
    DesktopEnabled = $true
    DesktopOnlyWhenCodexBackground = $true
    DesktopCompletion = $true
    DesktopPermissionRequest = $true
    ScheduleStart = '18:40'
    ScheduleEnd = '02:00'
    IntervalMinutes = 1
    HolidayRegion = 'None'
    HolidayCalendarPath = ''
    AllDayWeekdays = @('Saturday', 'Sunday')
    MaxQueueAgeHours = 24
    IncludeTaskPreview = $true
    IncludeResultPreview = $true
    IncludePermissionTool = $false
    MessageFormat = 'card'
}
$guiValidation = Test-CfnGuiModel $guiModel
Assert-True $guiValidation.Valid 'The graphical settings model must accept a valid configuration.'
$guiParameters = Get-CfnGuiInstallParameters $guiModel
Assert-True ($guiParameters.TaskName -eq 'Codex.GuiTest' -and $guiParameters.HolidayRegion -eq 'None') 'The GUI must map target and holiday settings to installer parameters.'
Assert-True (@($guiParameters.AllDayWeekdays).Count -eq 2 -and $guiParameters.AllDayWeekdays[0] -eq 'Saturday' -and $guiParameters.AllDayWeekdays[1] -eq 'Sunday') 'The GUI must map selected all-day weekdays to installer parameters.'
Assert-True ($guiParameters.NoLarkProfile -and -not $guiParameters.AllThreads -and -not $guiParameters.IncludeBridgeOrigin) 'The GUI must map checkbox semantics to installer switches.'
Assert-True (-not $guiParameters.NoStrictCompletionGate -and -not $guiParameters.NoPermissionNotifications) 'The GUI must enable lifecycle notifications by default.'
Assert-True (-not $guiParameters.NoDesktopToast -and -not $guiParameters.DesktopAlways -and $guiParameters.MessageFormat -eq 'card') 'The GUI must keep desktop foreground policy separate from Feishu card delivery.'
Assert-True (-not $guiParameters.NoFeishuNotifications -and -not $guiParameters.DisableScheduledTask) 'The GUI must preserve enabled Feishu and schedule switches.'

$guiModel.AllDayWeekdays = @()
$emptyWeekdayParameters = Get-CfnGuiInstallParameters $guiModel
Assert-True (-not $emptyWeekdayParameters.ContainsKey('AllDayWeekdays')) 'The GUI must omit an empty weekday array so PowerShell does not bind it as null and fail installer ValidateSet.'
$guiModel.AllDayWeekdays = @('Saturday', 'Sunday')

$guiModel.HolidayRegion = 'Custom'
$guiModel.HolidayCalendarPath = $sgCalendarPath
$customValidation = Test-CfnGuiModel $guiModel
$customParameters = Get-CfnGuiInstallParameters $guiModel
Assert-True $customValidation.Valid 'The graphical settings model must validate a custom holiday calendar.'
Assert-True ($customParameters.HolidayRegion -eq 'Auto' -and $customParameters.HolidayCalendarPath -eq $sgCalendarPath) 'A custom calendar must be passed to the installer without inventing a region.'

# The GUI module imports the core module as a nested dependency. Re-import it
# into the caller scope before exercising core state functions directly.
Import-Module $modulePath -Force -DisableNameChecking

$scheduleSettings = [pscustomobject]@{
    ScheduleStart = '18:40'
    ScheduleEnd = '02:00'
    AllDayWeekdays = @()
    HolidayRegion = 'None'
    HolidayCalendarPath = ''
}
Assert-True (-not (Test-CfnScheduleActive $scheduleSettings ([datetime]'2026-08-27 10:00'))) 'The delivery schedule must be inactive before a normal evening window.'
Assert-True (Test-CfnScheduleActive $scheduleSettings ([datetime]'2026-08-27 20:00')) 'The delivery schedule must be active after the evening start.'
Assert-True (Test-CfnScheduleActive $scheduleSettings ([datetime]'2026-08-28 01:00')) 'A cross-midnight delivery window must remain active after midnight.'
Assert-True (-not (Test-CfnScheduleActive $scheduleSettings ([datetime]'2026-08-28 03:00'))) 'The delivery schedule must end at the configured morning boundary.'
Assert-True ((Get-CfnNextScheduleStart $scheduleSettings ([datetime]'2026-08-27 20:00')) -eq [datetime]'2026-08-28 18:40') 'A pause during the window must expire at the next daily start.'
$scheduleSettings.AllDayWeekdays = @('Friday')
Assert-True (Test-CfnScheduleActive $scheduleSettings ([datetime]'2026-08-28 10:00')) 'A selected all-day weekday must be active outside the daily window.'
Assert-True ((Get-CfnNextScheduleStart $scheduleSettings ([datetime]'2026-08-28 10:00')) -eq [datetime]'2026-08-28 18:40') 'Manual pause on an all-day date must resume at the next concrete schedule trigger boundary.'
$scheduleSettings.AllDayWeekdays = @()

$tempIntegration = Join-Path ([System.IO.Path]::GetTempPath()) ("cfn-integration-$PID")
try {
    New-Item -ItemType Directory -Path $tempIntegration -Force | Out-Null
    $manualState = Set-CfnManualDeliveryState $tempIntegration 'force' `
        ([datetimeoffset]([datetime]'2026-08-27 18:40')) ([datetimeoffset]([datetime]'2026-08-27 10:00'))
    $manualControl = Get-CfnDeliveryControlState $tempIntegration $scheduleSettings ([datetime]'2026-08-27 10:00')
    Assert-True ($manualState.Mode -eq 'force' -and $manualControl.EffectiveActive -and $manualControl.Reason -eq 'manual_force') 'A temporary force state must activate delivery outside the saved schedule.'
    $expiredManualState = Get-CfnManualDeliveryState $tempIntegration -Now ([datetimeoffset]([datetime]'2026-08-27 18:41'))
    Assert-True ($null -eq $expiredManualState -and -not (Test-Path -LiteralPath (Get-CfnManualDeliveryStatePath $tempIntegration))) 'An expired manual override must remove itself and return control to the saved schedule.'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Destination $tempIntegration
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\notify.ps1') -Destination $tempIntegration
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\hook.ps1') -Destination $tempIntegration
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\drain.ps1') -Destination $tempIntegration
    $testSettings = $example | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $testSettings.filters.visible_threads_only = $false
    $testSettings.desktop.enabled = $false
    $testSettings.delivery.all_day_weekdays = @('Sunday', 'Monday', 'Sunday')
    [System.IO.File]::WriteAllText(
        (Join-Path $tempIntegration 'settings.local.json'),
        ($testSettings | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )

    function Invoke-CfnTestHook {
        param([Parameter(Mandatory = $true)] [string] $Json)
        $executable = (Get-Process -Id $PID).Path
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $executable
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $tempIntegration 'hook.ps1')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $process.StandardInput.Write($Json)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit(15000) | Out-Null
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
        $process.Dispose()
        return $result
    }

    $sessionStartPayload = [ordered]@{
        session_id = 'test-thread'
        cwd = 'C:\example\workspace'
        hook_event_name = 'SessionStart'
        source = 'startup'
    } | ConvertTo-Json -Compress
    $sessionStartResult = Invoke-CfnTestHook $sessionStartPayload
    Assert-True ($sessionStartResult.ExitCode -eq 0 -and -not $sessionStartResult.Stdout) 'SessionStart must create readiness without model-visible output.'
    Assert-True (Test-CfnLifecycleReady $tempIntegration 'test-thread' 720) 'A new Codex session must be marked ready for strict completion gating.'

    $permissionPayload = [ordered]@{
        session_id = 'test-thread'
        turn_id = 'permission-turn'
        cwd = 'C:\example\workspace'
        hook_event_name = 'PermissionRequest'
        tool_name = 'Bash'
        tool_input = [ordered]@{ command = 'secret command deliberately ignored' }
    } | ConvertTo-Json -Compress
    $permissionResult = Invoke-CfnTestHook $permissionPayload
    Assert-True ($permissionResult.ExitCode -eq 0 -and -not $permissionResult.Stdout) 'PermissionRequest notification hooks must return quickly without approval output.'
    $waitingItems = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($waitingItems.Count -eq 1) 'A PermissionRequest must create one waiting queue item.'
    $waitingItem = Get-Content -LiteralPath $waitingItems[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($waitingItem.kind -eq 'needs-input' -and -not $waitingItem.permission_tool) 'Permission events must omit tool details by default.'

    $resumePayload = [ordered]@{
        session_id = 'test-thread'
        turn_id = 'permission-turn'
        cwd = 'C:\example\workspace'
        hook_event_name = 'PostToolUse'
        tool_name = 'Bash'
    } | ConvertTo-Json -Compress
    $resumeResult = Invoke-CfnTestHook $resumePayload
    $waitingAfterResume = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($resumeResult.ExitCode -eq 0 -and $waitingAfterResume.Count -eq 0) 'PostToolUse must cancel an unsent waiting event.'

    $stopPayload = [ordered]@{
        session_id = 'test-thread'
        turn_id = 'test-turn'
        cwd = 'C:\example\workspace'
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Completed'
    } | ConvertTo-Json -Compress
    $stopResult = Invoke-CfnTestHook $stopPayload
    Assert-True ($stopResult.ExitCode -eq 0 -and $stopResult.Stdout -eq '{"continue":true}') 'Stop hooks must emit valid non-blocking JSON.'

    $payload = [ordered]@{
        type = 'agent-turn-complete'
        'thread-id' = 'test-thread'
        'turn-id' = 'test-turn'
        cwd = 'C:\example\workspace'
        'input-messages' = @('Run a safe test')
        'last-assistant-message' = 'Completed'
    } | ConvertTo-Json -Compress
    & (Join-Path $tempIntegration 'notify.ps1') $payload
    $queued = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($queued.Count -eq 1) 'A valid completion event must create exactly one queue item.'
    $completionItem = Get-Content -LiteralPath $queued[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($completionItem.kind -eq 'completed' -and $completionItem.schema -eq 2) 'Strictly released completions must use the version 2 queue schema.'
    & (Join-Path $tempIntegration 'notify.ps1') $payload
    $queuedAgain = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($queuedAgain.Count -eq 1) 'Duplicate completion events must not create duplicate queue items.'

    $unarmedPayload = [ordered]@{
        type = 'agent-turn-complete'
        'thread-id' = 'unarmed-thread'
        'turn-id' = 'unarmed-turn'
        cwd = 'C:\example\workspace'
        'input-messages' = @('Do not notify yet')
        'last-assistant-message' = 'Partial result'
    } | ConvertTo-Json -Compress
    [void](Set-CfnLifecycleReady $tempIntegration 'unarmed-thread')
    & (Join-Path $tempIntegration 'notify.ps1') $unarmedPayload
    $afterUnarmed = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($afterUnarmed.Count -eq 1) 'An unarmed completion must fail closed.'

    $legacyPayload = [ordered]@{
        type = 'agent-turn-complete'
        'thread-id' = 'legacy-open-thread'
        'turn-id' = 'legacy-turn'
        cwd = 'C:\example\workspace'
        'input-messages' = @('Session opened before hook installation')
        'last-assistant-message' = 'Completed during compatibility window'
    } | ConvertTo-Json -Compress
    & (Join-Path $tempIntegration 'notify.ps1') $legacyPayload
    $afterLegacy = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($afterLegacy.Count -eq 2) 'A pre-install session without SessionStart readiness must keep compatibility delivery.'

    Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
    $testSettings.transport.enabled = $false
    [System.IO.File]::WriteAllText(
        (Join-Path $tempIntegration 'settings.local.json'),
        ($testSettings | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $disabledSettings = Get-CfnSettings $tempIntegration
    Assert-True (-not $disabledSettings.FeishuEnabled) 'The runtime must load the Feishu notification switch.'
    Assert-True ((@($disabledSettings.AllDayWeekdays) -join ',') -eq 'Monday,Sunday') 'The runtime must validate, deduplicate, and normalize all-day weekdays.'

    $disabledPermissionPayload = [ordered]@{
        session_id = 'disabled-thread'
        turn_id = 'disabled-permission'
        cwd = 'C:\example\workspace'
        hook_event_name = 'PermissionRequest'
        tool_name = 'Bash'
    } | ConvertTo-Json -Compress
    $disabledPermissionResult = Invoke-CfnTestHook $disabledPermissionPayload
    $disabledPermissionQueue = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($disabledPermissionResult.ExitCode -eq 0 -and $disabledPermissionQueue.Count -eq 0) 'Disabled Feishu notifications must not queue permission events.'

    $disabledCompletionPayload = [ordered]@{
        type = 'agent-turn-complete'
        'thread-id' = 'disabled-completion-thread'
        'turn-id' = 'disabled-completion-turn'
        cwd = 'C:\example\workspace'
        'input-messages' = @('Complete without Feishu delivery')
        'last-assistant-message' = 'Completed locally'
    } | ConvertTo-Json -Compress
    & (Join-Path $tempIntegration 'notify.ps1') $disabledCompletionPayload
    $disabledCompletionQueue = @(Get-ChildItem -LiteralPath (Join-Path $tempIntegration 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($disabledCompletionQueue.Count -eq 0) 'Disabled Feishu notifications must not queue completion events.'

    $pendingRoot = Join-Path $tempIntegration 'spool\pending'
    Ensure-CfnDirectory $pendingRoot
    [System.IO.File]::WriteAllText((Join-Path $pendingRoot 'manual-test.json'), '{"event_id":"manual-test"}', (New-Object System.Text.UTF8Encoding($false)))
    & (Join-Path $tempIntegration 'drain.ps1')
    Assert-True (Test-Path -LiteralPath (Join-Path $pendingRoot 'manual-test.json')) 'The drain must not deliver or remove queued items while Feishu is disabled.'
    $enabledOutcome = Set-CfnGuiFeishuEnabled -InstallRoot $tempIntegration -Enabled $true
    Assert-True ($enabledOutcome.Enabled -and (Test-Path -LiteralPath $enabledOutcome.BackupPath) -and (Get-CfnSettings $tempIntegration).FeishuEnabled) 'The immediate GUI switch must persist and back up the enabled state.'
    Assert-True (Test-Path -LiteralPath (Join-Path $pendingRoot 'manual-test.json')) 'Enabling Feishu must not mutate an existing queue item.'
    $disabledOutcome = Set-CfnGuiFeishuEnabled -InstallRoot $tempIntegration -Enabled $false
    Assert-True (-not $disabledOutcome.Enabled -and (Test-Path -LiteralPath $disabledOutcome.BackupPath) -and -not (Get-CfnSettings $tempIntegration).FeishuEnabled) 'The immediate GUI switch must persist and back up the disabled state.'
    Assert-True ($disabledOutcome.SuppressedCount -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $pendingRoot 'manual-test.json'))) 'Disabling Feishu must move pending items to the recoverable suppressed queue.'
} finally {
    Remove-Item -LiteralPath $tempIntegration -Recurse -Force -ErrorAction SilentlyContinue
}

$notifySource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\notify.ps1') -Raw
Assert-True (-not [regex]::IsMatch($notifySource, '(?m)^\s*Start-ScheduledTask\b')) 'notify.ps1 must never start the scheduled task.'
Assert-True ($notifySource -match "agent-turn-complete") 'notify.ps1 must filter for Codex completion events.'
Assert-True ($notifySource -match 'Use-CfnCompletionArm') 'notify.ps1 must enforce the completion gate.'

$hookSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\hook.ps1') -Raw
Assert-True (-not [regex]::IsMatch($hookSource, '(?m)^\s*Start-ScheduledTask\b')) 'Lifecycle hooks must never start the scheduled task.'
Assert-True ($hookSource -match 'SessionStart' -and $hookSource -match 'PermissionRequest' -and $hookSource -match 'PostToolUse' -and $hookSource -match "'Stop'") 'Lifecycle hooks must cover readiness, waiting, resolution, and completion arming.'
Assert-True ($hookSource -notmatch 'behavior.{0,30}(allow|deny)' -and $hookSource -notmatch 'decision.{0,30}block') 'Notification hooks must never decide approvals or continue tasks.'

$guiSource = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Settings-Gui.ps1') -Raw
$guiModuleSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\CodexFeishuNotify.Gui.psm1') -Raw
$drainSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\drain.ps1') -Raw
Assert-True (-not [regex]::IsMatch($guiSource, '(?m)^\s*Start-ScheduledTask\b')) 'The settings GUI must never manually start the scheduled task.'
Assert-True ($guiSource -match 'Install\.ps1' -and $guiSource -match 'Test-Configuration\.ps1') 'The settings GUI must apply and verify through the existing project scripts.'
Assert-True ($guiSource -match 'FormBorderStyle\]::Sizable' -and $guiSource -notmatch 'FormBorderStyle\]::FixedDialog') 'The settings GUI must remain resizable.'
Assert-True ($guiSource -match 'System\.Windows\.Forms\.TabControl' -and $guiSource -match 'AutoScroll\s*=\s*\$true') 'The settings GUI must use scrollable tabbed settings pages.'
Assert-True ($guiSource -match 'Screen\]::FromControl' -and $guiSource -match 'WorkingArea') 'The settings GUI must fit itself to the active display work area.'
Assert-True ($guiSource -match '运行计划：已开启' -and $guiSource -match '运行计划：已关闭' -and $guiSource -match '飞书通知：已开启' -and $guiSource -match '飞书通知：已关闭') 'The settings GUI must expose immediate schedule and Feishu state toggles.'
Assert-True ($guiSource -match 'Appearance\]::Button' -and $guiSource -notmatch 'scheduleEnabledCheck' -and $guiSource -notmatch '启用计划任务（应用设置后保持该状态）') 'The schedule state must use one immediate persisted toggle instead of duplicate controls.'
Assert-True ($guiSource -match 'Set-CfnFeishuToggleState' -and $guiSource -notmatch 'feishuEnabledCheck' -and $guiSource -notmatch '启用飞书通知（应用设置后生效）') 'The Feishu state must use one immediate persisted toggle instead of duplicate controls.'
Assert-True ($guiSource -match '仅通知已登记在 Codex 桌面端的任务（推荐）' -and $guiSource -notmatch '仅处理用户可见的 Codex 任务') 'The visible-thread filter label must describe the actual desktop-registration heuristic.'
Assert-True ($guiSource -match '当前读取来源：' -and $guiSource -match 'SourcePath') 'The settings GUI must display the full path used as its current configuration source.'
Assert-True ($guiSource -match '留空＝自动查找' -and $guiSource -match 'EM_SETCUEBANNER') 'The lark-cli field must explain that an empty value enables automatic discovery.'
Assert-True ($guiSource -match '已自动找到：' -and $guiSource -match 'Update-CfnLarkCliResolution') 'The settings GUI must display the resolved lark-cli path beside the field.'
Assert-True ($guiSource -match '使用独立 Lark profile（推荐）' -and $guiSource -match 'ComboBoxStyle\]::DropDownList' -and $guiSource -notmatch 'profileText') 'The profile selector must be an existing-profile drop-down with the recommended isolation label.'
Assert-True ($guiSource -match 'requireProfileCheck\.Add_CheckedChanged' -and $guiSource -match 'profileCombo\.Enabled') 'Clearing the independent-profile option must disable the profile drop-down.'
Assert-True ($guiSource -match 'desktopEnabledCheck\.Add_CheckedChanged' -and $guiSource -match 'Update-CfnDesktopControls' -and $guiSource -match 'control\.Enabled\s*=\s*\$enabled') 'Clearing the PC notification option must disable all dependent desktop-notification choices.'
Assert-True ($guiSource -match "basicTab\.Text\s*=\s*'飞书连接'" -and $guiSource -match "scheduleTab\.Text\s*=\s*'运行计划'" -and $guiSource -match 'scheduleStack\.Controls\.Add\(\$scheduleGroup') 'The run schedule must have its own tab separate from Feishu connection settings.'
Assert-True ($guiSource -match '全天运行日' -and $guiSource -match "Monday\s*=\s*'周一'" -and $guiSource -match "Sunday\s*=\s*'周日'" -and $guiSource -match 'holidayModeExplanation') 'The schedule tab must explain holiday behavior and expose Monday-through-Sunday all-day choices.'
Assert-True ($guiSource -match 'TextRenderer\]::MeasureText' -and $guiSource -match 'holiday_explanation_reflows' -and $guiSource -match 'SizeType\]::AutoSize') 'The holiday explanation row must shrink to one line and grow only when its measured text wraps.'
Assert-True ($guiSource -match "uninstallButton\.Text\s*=\s*'卸载通知'" -and $guiSource -match 'basicStack\.Controls\.Add\(\$maintenanceGroup,\s*0,\s*2\)' -and $guiSource -notmatch 'actionBar\.Controls\.Add\(\$uninstallButton\)') 'The uninstall notification button must be the final section of the Feishu connection tab, not a global action-bar command.'
Assert-True ($guiSource -match "installButton\.Text\s*=\s*'安装通知'" -and $guiSource -match "Invoke-CfnGuiDeployment\s+-Mode\s+'Install'" -and $guiSource -notmatch 'actionBar\.Controls\.Add\(\$installButton\)') 'The maintenance section must expose an install/repair button backed by the shared installer workflow.'
Assert-True ($guiSource -match '修复 Codex notify 命令链' -and $guiSource -match '审查、信任和启用' -and $guiSource -match '不会绕过此安全步骤') 'The install flow must explain notify repair and the separate Codex hook-trust step.'
Assert-True ($guiSource -match "instantDeliveryButton\.Text\s*=\s*'马上开始'" -and $guiSource -match "'立刻停止'" -and $guiSource -match 'Invoke-CfnGuiManualDeliveryToggle') 'The schedule tab must expose one dynamic immediate start/stop control.'
Assert-True ($guiModuleSource -match 'CodexFeishuNotify\.ManualOverride' -and $guiModuleSource -match 'Set-CfnManualDeliveryState' -and $guiModuleSource -match 'WindowStyle Hidden') 'Immediate running must use an expiring named trigger and a hidden first drain.'
Assert-True ($drainSource -match 'Get-CfnDeliveryControlState' -and $drainSource -match 'EffectiveActive') 'The drain must enforce saved schedule and manual pause/force state before sending.'
Assert-True ($guiModuleSource -match 'ConvertFrom-Json' -and $guiModuleSource -match 'PSObject\.Properties\[\$eventName\]') 'GUI hook status must parse hooks.json instead of matching escaped JSON text.'
Assert-True ($guiModuleSource -match 'foreach \(\$candidate in @\(''Codex\.LarkNotify\.codex'', ''Codex\.FeishuNotify''\)\)' -and $guiModuleSource -match 'else \{\s*\$TaskName = ''Codex\.LarkNotify\.codex''\s*\}') 'The GUI must preserve compatible tasks but default a clean-machine install to Codex.LarkNotify.codex.'
Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'Open-Settings.cmd') -PathType Leaf) 'The project must include a double-click GUI launcher.'

$installerSource = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Install.ps1') -Raw
Assert-True ($installerSource -match 'Get-CfnUpdatedHooksJson' -and $installerSource -match 'hooks\.json\.before-') 'The installer must merge and back up lifecycle hooks.'
Assert-True ($installerSource -match 'deployment-' -and $installerSource -match 'AllowDemandStart') 'The installer must snapshot upgrades and verify demand start stays disabled.'
Assert-True ($installerSource -match 'NoFeishuNotifications' -and $installerSource -match 'DisableScheduledTask' -and $installerSource -match 'Move-CfnPendingToSuppressed') 'The installer must persist both manual switches and suppress pending Feishu items when disabled.'
Assert-True ($installerSource -match 'AllDayWeekdays' -and $installerSource -match 'New-ScheduledTaskTrigger\s+-Weekly') 'The installer must persist all-day weekdays and create true weekly gap triggers.'

$gitIgnore = Get-Content -LiteralPath (Join-Path $projectRoot '.gitignore') -Raw
Assert-True ($gitIgnore -match '(?m)^settings\.local\.json\r?$') 'settings.local.json must be ignored by Git.'
Assert-True ($gitIgnore -match '(?m)^holidays\.local\.json\r?$') 'The installed holiday calendar must be ignored by Git.'
Assert-True ($gitIgnore -match '(?m)^spool/\r?$') 'Spool data must be ignored by Git.'
Assert-True ($gitIgnore -match '(?m)^logs/\r?$') 'Logs must be ignored by Git.'

$trackedCandidates = Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -notmatch '[\\/]dist[\\/]' -and
    $_.Name -notmatch '^settings\.local\.json$'
}
$secretPatterns = @(
    ('C:\\Users\\' + [regex]::Escape($env:USERNAME)),
    '\boc_[0-9a-f]{24,}\b',
    'https://open\.feishu\.cn/open-apis/bot/v2/hook/[A-Za-z0-9_-]{10,}',
    '\bsk-[A-Za-z0-9_-]{20,}\b'
)
foreach ($file in $trackedCandidates) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($pattern in $secretPatterns) {
        Assert-True (-not [regex]::IsMatch([string]$text, $pattern)) "Potential machine-specific value or secret in $($file.FullName)"
    }
}

if ($failures.Count -gt 0) {
    Write-Host "FAILED ($($failures.Count))" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
    exit 1
}

Write-Host "PASS: $($powerShellFiles.Count) PowerShell files parsed and project invariants verified." -ForegroundColor Green
exit 0
