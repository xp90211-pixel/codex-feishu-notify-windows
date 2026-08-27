[CmdletBinding()]
param(
    [string] $InstallRoot = (Join-Path $env:USERPROFILE '.codex\integrations\codex-feishu-notify'),
    [string] $TaskName = 'Codex.FeishuNotify'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$InstallRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallRoot))
$results = New-Object System.Collections.Generic.List[object]
$settings = $null
$expectedHolidayTriggerCount = 0
$allDayWeekdays = @()

function Add-Check {
    param([string] $Name, [bool] $Passed, [string] $Detail)
    $results.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail })
}

function Test-NotifyCommandTarget {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Command,
        [Parameter(Mandatory = $true)] [string[]] $Targets,
        [int] $Depth = 0
    )
    if ($Depth -gt 4) { return $false }
    foreach ($argument in @($Command)) {
        $value = [string]$argument
        foreach ($target in $Targets) {
            if ($value.IndexOf($target, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
        if ($value.TrimStart().StartsWith('[')) {
            try {
                $nested = @($value | ConvertFrom-Json)
                if (Test-NotifyCommandTarget $nested $Targets ($Depth + 1)) { return $true }
            } catch {}
        }
    }
    return $false
}

$modulePath = Join-Path $InstallRoot 'CodexFeishuNotify.psm1'
Add-Check 'module_exists' (Test-Path -LiteralPath $modulePath) $modulePath
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force -DisableNameChecking
    try {
        $settings = Get-CfnSettings $InstallRoot
        $weekdayProperty = $settings.PSObject.Properties['AllDayWeekdays']
        if ($null -ne $weekdayProperty) { $allDayWeekdays = @($weekdayProperty.Value) }
        Add-Check 'settings_valid' $true 'settings.local.json parsed'
        Add-Check 'feishu_notifications' $true "enabled=$($settings.FeishuEnabled)"
        Add-Check 'message_format' ($settings.MessageFormat -in @('card', 'text')) $settings.MessageFormat
        Add-Check 'strict_completion_gate' $true "enabled=$($settings.StrictCompletionGate)"
        Add-Check 'desktop_foreground_policy' $true "enabled=$($settings.DesktopEnabled), only_when_background=$($settings.DesktopOnlyWhenCodexBackground)"
        Add-Check 'chat_id_configured' ($settings.ChatId -match '^oc_[A-Za-z0-9_-]+$' -and $settings.ChatId -notmatch 'REPLACE') 'chat id format only; value not printed'
        if ($settings.HolidayRegion -ne 'None') {
            try {
                $holidayCalendar = Get-CfnHolidayCalendar $settings.HolidayCalendarPath
                $futureHolidayCount = @($holidayCalendar.Holidays | Where-Object { $_.Date -ge (Get-Date).Date }).Count
                foreach ($holiday in @($holidayCalendar.Holidays | Where-Object {
                    $_.Date -ge (Get-Date).Date -and $allDayWeekdays -notcontains $_.Date.DayOfWeek.ToString()
                })) {
                    $expectedHolidayTriggerCount += @(Get-CfnHolidayGapWindows $holiday.Date $settings.ScheduleStart $settings.ScheduleEnd |
                        Where-Object { $_.Duration.TotalMinutes -ge $settings.IntervalMinutes }).Count
                }
                Add-Check 'holiday_calendar_valid' ($holidayCalendar.Region -eq $settings.HolidayRegion -and $futureHolidayCount -gt 0) "region=$($holidayCalendar.Region), future_dates=$futureHolidayCount"
            } catch {
                Add-Check 'holiday_calendar_valid' $false $_.Exception.Message
            }
        } else {
            Add-Check 'holiday_calendar_disabled' $true 'region=None'
        }
        $cli = Find-CfnLarkCli $settings.LarkCliPath
        Add-Check 'lark_cli_found' ((-not $settings.FeishuEnabled) -or [bool]$cli) $(if ($cli) { $cli } elseif (-not $settings.FeishuEnabled) { 'not required while Feishu notifications are disabled' } else { 'not found' })
        if (-not $settings.FeishuEnabled) {
            Add-Check 'lark_profile_ready' $true 'not required while Feishu notifications are disabled'
        } else {
            try {
                Initialize-CfnLarkProfile $settings
                Add-Check 'lark_profile_ready' $true $settings.LarkChannelProfile
            } catch {
                Add-Check 'lark_profile_ready' $false $_.Exception.Message
            }
        }
    } catch {
        Add-Check 'settings_valid' $false $_.Exception.Message
    }
}

foreach ($name in @('notify.ps1', 'hook.ps1', 'drain.ps1', 'dispatch.ps1', 'CodexFeishuNotify.psm1')) {
    $path = Join-Path $InstallRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Check "syntax_$name" $false 'file missing'
        continue
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Add-Check "syntax_$name" ($errors.Count -eq 0) $(if ($errors.Count) { ($errors.Message -join '; ') } else { 'ok' })
}

$hooksPath = Join-Path $env:USERPROFILE '.codex\hooks.json'
$ownedHookCount = 0
if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
    try {
        $hookDocument = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($eventName in @('PermissionRequest', 'PostToolUse', 'UserPromptSubmit', 'SessionStart', 'Stop')) {
            $eventProperty = $hookDocument.hooks.PSObject.Properties[$eventName]
            if ($null -eq $eventProperty) { continue }
            $handlers = @(@($eventProperty.Value) | ForEach-Object { @($_.hooks) })
            if (@($handlers | Where-Object {
                $commandProperty = $_.PSObject.Properties['commandWindows']
                $fallbackProperty = $_.PSObject.Properties['command']
                $command = if ($null -ne $commandProperty) { [string]$commandProperty.Value } elseif ($null -ne $fallbackProperty) { [string]$fallbackProperty.Value } else { '' }
                $command.IndexOf((Join-Path $InstallRoot 'hook.ps1'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -eq 1) { $ownedHookCount++ }
        }
    } catch {
        Add-Check 'lifecycle_hooks_json' $false $_.Exception.Message
    }
}
Add-Check 'lifecycle_hooks' ($ownedHookCount -eq 5) "configured=$ownedHookCount/5, path=$hooksPath"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Add-Check 'task_exists' ([bool]$task) $TaskName
if ($task -and $null -ne $settings) {
    $dailyTriggers = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' })
    $weeklyTriggers = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger' })
    $manualTriggerId = 'CodexFeishuNotify.ManualOverride'
    $holidayTriggers = @($task.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' -and [string]$_.Id -ne $manualTriggerId
    })
    $manualTriggers = @($task.Triggers | Where-Object { [string]$_.Id -eq $manualTriggerId })
    $daily = $dailyTriggers | Select-Object -First 1
    Add-Check 'task_daily' ($dailyTriggers.Count -eq 1 -and $daily.DaysInterval -eq 1) "daily=$($dailyTriggers.Count)"
    Add-Check 'task_repetition' ([bool]$daily.Repetition.Interval -and [bool]$daily.Repetition.Duration) "$($daily.Repetition.Interval) / $($daily.Repetition.Duration)"
    $expectedWeeklyTriggerCount = if ($allDayWeekdays.Count -gt 0) {
        @(Get-CfnHolidayGapWindows ([datetime]::Today) $settings.ScheduleStart $settings.ScheduleEnd |
            Where-Object { $_.Duration.TotalMinutes -ge $settings.IntervalMinutes }).Count
    } else { 0 }
    Add-Check 'task_weekly_extensions' ($weeklyTriggers.Count -eq $expectedWeeklyTriggerCount) "weekdays=$($allDayWeekdays -join ','), triggers=$($weeklyTriggers.Count), expected=$expectedWeeklyTriggerCount"
    Add-Check 'task_holiday_extensions' ($holidayTriggers.Count -eq $expectedHolidayTriggerCount) "region=$($settings.HolidayRegion), triggers=$($holidayTriggers.Count), expected=$expectedHolidayTriggerCount"
    Add-Check 'task_manual_override' ($manualTriggers.Count -le 1) "temporary_triggers=$($manualTriggers.Count)"
    Add-Check 'task_no_catchup' (-not $task.Settings.StartWhenAvailable) "StartWhenAvailable=$($task.Settings.StartWhenAvailable)"
    Add-Check 'task_hidden' ([bool]$task.Settings.Hidden) "Hidden=$($task.Settings.Hidden)"
    Add-Check 'task_demand_start_disabled' (-not $task.Settings.AllowDemandStart) "AllowDemandStart=$($task.Settings.AllowDemandStart)"
    Add-Check 'task_schedule_switch' $true "enabled=$($task.State -ne 'Disabled'), state=$($task.State)"
}

$configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$hookFound = $false
if (Test-Path -LiteralPath $configPath) {
    try {
        $configText = Get-Content -LiteralPath $configPath -Raw
        $match = [regex]::Match($configText, '(?m)^\s*notify\s*=\s*(?<value>[^\r\n]+)')
        if ($match.Success) {
            $command = @($match.Groups['value'].Value | ConvertFrom-Json)
            $hookFound = Test-NotifyCommandTarget $command @(
                (Join-Path $InstallRoot 'notify.ps1'),
                (Join-Path $InstallRoot 'dispatch.ps1')
            )
        }
    } catch {}
}
Add-Check 'codex_hook_configured' $hookFound 'user-level config.toml'

$pendingCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
$suppressedCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\suppressed') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
Add-Check 'queue_readable' $true "pending=$pendingCount, suppressed=$suppressedCount"

$results | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
exit 0
