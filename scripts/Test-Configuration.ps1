[CmdletBinding()]
param(
    [string] $InstallRoot = '',
    [string] $TaskName = 'Codex.FeishuNotify'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\src\CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
if (-not $InstallRoot) { $InstallRoot = Join-Path (Get-CfnCodexHome) 'integrations\codex-feishu-notify' }
$InstallRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallRoot))
$results = New-Object System.Collections.Generic.List[object]
$settings = $null
$holidayCalendar = $null
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
Add-Check 'notification_host_exists' (Test-Path -LiteralPath (Join-Path $InstallRoot 'notification-host.exe') -PathType Leaf) 'GUI-subsystem notification launcher'
Add-Check 'module_exists' (Test-Path -LiteralPath $modulePath) $modulePath
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force -DisableNameChecking
    try {
        $settings = Get-CfnSettings $InstallRoot
        $weekdayProperty = $settings.PSObject.Properties['AllDayWeekdays']
        if ($null -ne $weekdayProperty) { $allDayWeekdays = @($weekdayProperty.Value) }
        Add-Check 'settings_valid' $true 'settings.local.json parsed'
        Add-Check 'feishu_notifications' $true "enabled=$($settings.FeishuEnabled)"
        Add-Check 'fresh_notifications_only' $true "enabled=$($settings.FreshNotificationsOnly)"
        Import-Module (Join-Path $InstallRoot 'CfnIdleReminder.psm1') -Force -DisableNameChecking
        $idleOptions = Get-CfnIdleOptions $InstallRoot
        Add-Check 'all_idle_reminder' $true "enabled=$($null -ne $idleOptions); live app status not probed"
        Add-Check 'message_format' ($settings.MessageFormat -in @('card', 'text')) $settings.MessageFormat
        Add-Check 'strict_completion_gate' $true "enabled=$($settings.StrictCompletionGate)"
        Add-Check 'desktop_foreground_policy' $true "enabled=$($settings.DesktopEnabled), only_when_background=$($settings.DesktopOnlyWhenCodexBackground)"
        Add-Check 'chat_id_configured' ((-not $settings.FeishuEnabled) -or ($settings.ChatId -match '^oc_[A-Za-z0-9_-]+$' -and $settings.ChatId -notmatch 'REPLACE')) 'chat id format only; value not printed'
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
                Add-Check 'holiday_calendar_valid' ($holidayCalendar.Region -eq $settings.HolidayRegion) "region=$($holidayCalendar.Region), future_dates=$futureHolidayCount"
            } catch {
                Add-Check 'holiday_calendar_valid' $false $_.Exception.Message
            }
        } else {
            Add-Check 'holiday_calendar_disabled' $true 'region=None'
        }
        $cli = Find-CfnLarkCli $settings.LarkCliPath
        Add-Check 'lark_cli_found' ((-not $settings.FeishuEnabled) -or [bool]$cli) $(if ($cli) { $cli } elseif (-not $settings.FeishuEnabled) { 'not required while Feishu notifications are disabled' } else { 'not found' })
        if ($settings.FeishuEnabled -and $cli) {
            try { Add-Check 'lark_cli_native' $true (Resolve-CfnNativeCli $cli) }
            catch { Add-Check 'lark_cli_native' $false $_.Exception.Message }
        }
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

foreach ($name in @('notify.ps1', 'hook.ps1', 'drain.ps1', 'dispatch.ps1', 'CodexFeishuNotify.psm1', 'CfnIdleReminder.psm1')) {
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

$hooksPath = Join-Path (Get-CfnCodexHome $InstallRoot) 'hooks.json'
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

$manifestPath = Join-Path $InstallRoot 'install-state.json'
if (-not $PSBoundParameters.ContainsKey('TaskName') -and (Test-Path -LiteralPath $manifestPath)) {
    $manifest = Read-CfnUtf8File $manifestPath | ConvertFrom-Json
    $TaskName = [string](Get-CfnProperty $manifest 'task_name' $TaskName)
}
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Add-Check 'task_exists' ([bool]$task) $TaskName
if ($task -and $null -ne $settings) {
    $plan = @(Get-CfnSchedulePlan -Start $settings.ScheduleStart -End $settings.ScheduleEnd -IntervalMinutes $settings.IntervalMinutes -AllDayWeekdays $allDayWeekdays -Calendar $holidayCalendar)
    Add-Check 'task_schedule_matches' (Test-CfnScheduleTriggers $task $plan) 'times and repetition match shared schedule plan; past one-time triggers ignored'
    Add-Check 'task_owned' (Test-CfnTaskOwnership $task $InstallRoot) 'action points to this installation'
    $manualTriggers = @($task.Triggers | Where-Object { [string]$_.Id -eq 'CodexFeishuNotify.ManualOverride' })
    Add-Check 'task_manual_override' ($manualTriggers.Count -le 1) "temporary_triggers=$($manualTriggers.Count)"
    Add-Check 'task_no_catchup' (-not $task.Settings.StartWhenAvailable) "StartWhenAvailable=$($task.Settings.StartWhenAvailable)"
    Add-Check 'task_hidden' ([bool]$task.Settings.Hidden) "Hidden=$($task.Settings.Hidden)"
    Add-Check 'task_demand_start_disabled' (-not $task.Settings.AllowDemandStart) "AllowDemandStart=$($task.Settings.AllowDemandStart)"
    Add-Check 'task_schedule_switch' (($task.State -ne 'Disabled') -eq $settings.ScheduleEnabled) "enabled=$($task.State -ne 'Disabled'), state=$($task.State)"
}

$configPath = Join-Path (Get-CfnCodexHome $InstallRoot) 'config.toml'
$hookFound = $false
if (Test-Path -LiteralPath $configPath) {
    try {
        $configText = Read-CfnUtf8File $configPath
        $record = Get-CfnNotifyRecord $configText
        if ($record.Found) {
            $command = @(ConvertFrom-CfnNotifyLine $record.Line)
            $hookFound = Test-NotifyCommandTarget $command @(
                (Join-Path $InstallRoot 'notify.ps1'),
                (Join-Path $InstallRoot 'dispatch.ps1'),
                (Join-Path $InstallRoot 'notification-host.exe')
            )
        }
    } catch {}
}
Add-Check 'codex_hook_configured' $hookFound 'user-level config.toml'

$pendingCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
$suppressedCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\suppressed') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
Add-Check 'desktop_registration_filter' $true 'known JSON fields only; unknown schema or false fail closed; not an authorization boundary'
Add-Check 'queue_readable' $true "pending=$pendingCount, suppressed=$suppressedCount"

$results | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
exit 0
