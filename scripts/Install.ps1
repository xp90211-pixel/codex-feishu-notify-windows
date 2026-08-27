[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ChatId = '',
    [string] $InstallRoot = (Join-Path $env:USERPROFILE '.codex\integrations\codex-feishu-notify'),
    [string] $TaskName = 'Codex.FeishuNotify',
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')] [string] $ScheduleStart = '18:40',
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')] [string] $ScheduleEnd = '02:00',
    [ValidateRange(1, 60)] [int] $IntervalMinutes = 1,
    [ValidateRange(1, 720)] [int] $MaxQueueAgeHours = 24,
    [ValidateSet('Auto', 'SG', 'CN', 'None')] [string] $HolidayRegion = 'Auto',
    [string] $HolidayCalendarPath = '',
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')] [string[]] $AllDayWeekdays = @(),
    [string] $LarkCliPath = '',
    [string] $LarkChannelHome = '%USERPROFILE%\.lark-channel',
    [string] $LarkChannelProfile = 'codex',
    [switch] $NoLarkProfile,
    [switch] $NoFeishuNotifications,
    [switch] $DisableScheduledTask,
    [switch] $AllThreads,
    [switch] $IncludeBridgeOrigin,
    [switch] $NoTaskPreview,
    [switch] $NoResultPreview,
    [switch] $IncludePermissionTool,
    [ValidateSet('card', 'text')] [string] $MessageFormat = 'card',
    [ValidateRange(1, 5)] [int] $SendAttemptsPerRun = 2,
    [ValidateRange(0, 30)] [int] $RetryDelaySeconds = 2,
    [switch] $NoDesktopToast,
    [switch] $DesktopAlways,
    [switch] $NoDesktopCompletion,
    [switch] $NoDesktopPermissionRequest,
    [switch] $NoStrictCompletionGate,
    [switch] $NoPermissionNotifications,
    [switch] $SkipLifecycleHooks,
    [switch] $SkipCodexHook,
    [switch] $ReplaceUnparseableNotify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'This installer supports Windows only.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'src'
$modulePath = Join-Path $sourceRoot 'CodexFeishuNotify.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Project source is incomplete: $modulePath" }
Import-Module $modulePath -Force -DisableNameChecking

function Get-PowerShellExecutable {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { return $pwsh.Source }
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell) { return $windowsPowerShell }
    throw 'PowerShell executable was not found.'
}

function Get-NotifyLineRecord {
    param([string] $Text)

    $match = [regex]::Match($Text, '(?m)^(?<line>[ \t]*notify[ \t]*=[^\r\n]*)(?<ending>\r?\n|$)')
    if (-not $match.Success) {
        return [pscustomobject]@{ Found = $false; Line = ''; Match = $null }
    }
    return [pscustomobject]@{ Found = $true; Line = $match.Groups['line'].Value; Match = $match }
}

function ConvertFrom-NotifyLine {
    param([string] $Line)

    $equals = $Line.IndexOf('=')
    if ($equals -lt 0) { throw 'Invalid notify assignment.' }
    $rhs = $Line.Substring($equals + 1).Trim()
    return @($rhs | ConvertFrom-Json)
}

function ConvertTo-NotifyLine {
    param([object[]] $Command)
    return 'notify = ' + (ConvertTo-CfnTomlArray $Command)
}

function ConvertTo-CommandJson {
    param([object[]] $Command)
    return ConvertTo-Json -InputObject @($Command) -Compress -Depth 5
}

function Set-NotifyLine {
    param(
        [string] $Text,
        [string] $NewLine
    )

    $record = Get-NotifyLineRecord $Text
    if ($record.Found) {
        $ending = $record.Match.Groups['ending'].Value
        return $Text.Substring(0, $record.Match.Index) + $NewLine + $ending +
            $Text.Substring($record.Match.Index + $record.Match.Length)
    }
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += [Environment]::NewLine }
    return $Text + $NewLine + [Environment]::NewLine
}

function Test-ContainsLegacyNotifier {
    param([object[]] $Command)
    $joined = (@($Command) | ForEach-Object { [string]$_ }) -join "`n"
    return $joined -match '(?i)[\\/](lark-channel-notify|codex-feishu-notify)[\\/]notify\.ps1'
}

function Test-ContainsInstalledNotifier {
    param(
        [object[]] $Command,
        [string] $Root
    )
    $joined = (@($Command) | ForEach-Object { [string]$_ }) -join "`n"
    foreach ($name in @('notify.ps1', 'dispatch.ps1')) {
        $candidate = Join-Path $Root $name
        if ($joined.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function ConvertTo-CfnCommandLine {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)
    return (@($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
}

function Test-CfnLifecycleHandler {
    param(
        [AllowNull()] $Handler,
        [Parameter(Mandatory = $true)] [string] $Root
    )
    if ($null -eq $Handler) { return $false }
    $command = [string](Get-CfnProperty $Handler 'commandWindows' (Get-CfnProperty $Handler 'command' ''))
    return $command.IndexOf((Join-Path $Root 'hook.ps1'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Set-CfnLifecycleHookGroup {
    param(
        [Parameter(Mandatory = $true)] $HooksObject,
        [Parameter(Mandatory = $true)] [string] $EventName,
        [Parameter(Mandatory = $true)] $Handler,
        [Parameter(Mandatory = $true)] [string] $Root
    )

    $keptGroups = New-Object System.Collections.Generic.List[object]
    $eventProperty = $HooksObject.PSObject.Properties[$EventName]
    if ($null -ne $eventProperty) {
        foreach ($group in @($eventProperty.Value)) {
            $keptHandlers = @(@(Get-CfnProperty $group 'hooks' @()) | Where-Object { -not (Test-CfnLifecycleHandler $_ $Root) })
            if ($keptHandlers.Count -gt 0) {
                if ($null -eq $group.PSObject.Properties['hooks']) {
                    $group | Add-Member -MemberType NoteProperty -Name 'hooks' -Value $keptHandlers
                } else {
                    $group.hooks = $keptHandlers
                }
                $keptGroups.Add($group)
            }
        }
    }
    $keptGroups.Add([pscustomobject]@{ hooks = @($Handler) })
    if ($null -eq $eventProperty) {
        $HooksObject | Add-Member -MemberType NoteProperty -Name $EventName -Value $keptGroups.ToArray()
    } else {
        $eventProperty.Value = $keptGroups.ToArray()
    }
}

function Get-CfnUpdatedHooksJson {
    param(
        [AllowEmptyString()] [string] $ExistingText,
        [Parameter(Mandatory = $true)] [string] $CommandLine,
        [Parameter(Mandatory = $true)] [string] $Root
    )

    $document = if ([string]::IsNullOrWhiteSpace($ExistingText)) {
        [pscustomobject]@{
            description = 'User lifecycle hooks. Existing hooks are preserved by codex-feishu-notify-windows.'
            hooks = [pscustomobject]@{}
        }
    } else {
        try { $ExistingText | ConvertFrom-Json } catch { throw 'Existing ~/.codex/hooks.json is invalid JSON; it was not changed.' }
    }
    if ($null -eq $document.PSObject.Properties['hooks']) {
        $document | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{})
    }
    $hooksObject = $document.hooks
    if ($null -eq $hooksObject) {
        $hooksObject = [pscustomobject]@{}
        $document.hooks = $hooksObject
    }

    $asyncHandler = [pscustomobject]@{
        type = 'command'
        command = $CommandLine
        commandWindows = $CommandLine
        async = $true
        timeout = 10
    }
    $stopHandler = [pscustomobject]@{
        type = 'command'
        command = $CommandLine
        commandWindows = $CommandLine
        async = $false
        timeout = 10
    }
    Set-CfnLifecycleHookGroup $hooksObject 'PermissionRequest' $asyncHandler $Root
    Set-CfnLifecycleHookGroup $hooksObject 'PostToolUse' $asyncHandler $Root
    Set-CfnLifecycleHookGroup $hooksObject 'UserPromptSubmit' $asyncHandler $Root
    Set-CfnLifecycleHookGroup $hooksObject 'SessionStart' $stopHandler $Root
    Set-CfnLifecycleHookGroup $hooksObject 'Stop' $stopHandler $Root
    return $document | ConvertTo-Json -Depth 20
}

$InstallRoot = [System.IO.Path]::GetFullPath((Resolve-CfnPath $InstallRoot))
$powerShellPath = Get-PowerShellExecutable
$window = Get-CfnScheduleWindow $ScheduleStart $ScheduleEnd
if ($window.Duration.TotalMinutes -lt $IntervalMinutes) {
    throw 'The repetition interval cannot exceed the delivery window.'
}
$weekdayOrder = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$AllDayWeekdays = @($weekdayOrder | Where-Object { $AllDayWeekdays -contains $_ })

$resolvedHolidayRegion = $HolidayRegion
if ($HolidayCalendarPath) {
    $HolidayCalendarPath = [System.IO.Path]::GetFullPath((Resolve-CfnPath $HolidayCalendarPath))
} else {
    if ($resolvedHolidayRegion -eq 'Auto') {
        $geoId = try { (Get-WinHomeLocation).GeoId } catch { 0 }
        if ($geoId -eq 215) {
            $resolvedHolidayRegion = 'SG'
        } elseif ($geoId -eq 45 -or (Get-Culture).Name -eq 'zh-CN') {
            $resolvedHolidayRegion = 'CN'
        } else {
            $resolvedHolidayRegion = 'None'
        }
    }
    switch ($resolvedHolidayRegion) {
        'SG' { $HolidayCalendarPath = Join-Path $projectRoot 'config\holidays.sg.json' }
        'CN' { $HolidayCalendarPath = Join-Path $projectRoot 'config\holidays.cn.2026.json' }
        'None' { $HolidayCalendarPath = '' }
    }
}

$holidayCalendar = $null
if ($HolidayCalendarPath) {
    $holidayCalendar = Get-CfnHolidayCalendar $HolidayCalendarPath
    $resolvedHolidayRegion = $holidayCalendar.Region
}

$existingSettingsPath = Join-Path $InstallRoot 'settings.local.json'
if (-not $ChatId -and (Test-Path -LiteralPath $existingSettingsPath)) {
    try {
        $existingSettings = Get-Content -LiteralPath $existingSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ChatId = [string](Get-CfnProperty (Get-CfnProperty $existingSettings 'transport' $null) 'chat_id' '')
    } catch {}
}
if (-not $ChatId) {
    $legacyDrainPath = Join-Path $InstallRoot 'drain.ps1'
    if (Test-Path -LiteralPath $legacyDrainPath -PathType Leaf) {
        try {
            $legacyText = Get-Content -LiteralPath $legacyDrainPath -Raw
            $legacyMatch = [regex]::Match($legacyText, '(?m)^\s*\$ChatId\s*=\s*(?<quote>[''"])(?<value>oc_[A-Za-z0-9_-]+)\k<quote>\s*$')
            if ($legacyMatch.Success) { $ChatId = $legacyMatch.Groups['value'].Value }
        } catch {}
    }
}
if ([string]::IsNullOrWhiteSpace($ChatId) -or $ChatId -match 'REPLACE') {
    throw 'Provide the target Feishu chat id with -ChatId oc_xxx. It is saved only in the ignored local settings file.'
}

$codexRoot = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexRoot 'config.toml'
if (-not (Test-Path -LiteralPath $configPath)) {
    Ensure-CfnDirectory $codexRoot
    $configText = ''
} else {
    $configText = Get-Content -LiteralPath $configPath -Raw
}

$hookCommand = @(
    $powerShellPath, '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $InstallRoot 'notify.ps1')
)
$dispatchCommand = @(
    $powerShellPath, '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $InstallRoot 'dispatch.ps1')
)
$hooksPath = Join-Path $codexRoot 'hooks.json'
$hooksText = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
    Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8
} else { '' }
$lifecycleCommand = ConvertTo-CfnCommandLine @(
    $powerShellPath, '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $InstallRoot 'hook.ps1')
)
$updatedHooksText = if ($SkipLifecycleHooks) { '' } else {
    Get-CfnUpdatedHooksJson $hooksText $lifecycleCommand $InstallRoot
}
$originalNotify = Get-NotifyLineRecord $configText
$newNotifyCommand = $hookCommand
$previousNotifyCommand = $null
$hookMode = 'direct'
$isUpgrade = $false
$priorStatePath = Join-Path $InstallRoot 'install-state.json'
$priorState = if (Test-Path -LiteralPath $priorStatePath) {
    try { Get-Content -LiteralPath $priorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
} else { $null }

if (-not $SkipCodexHook -and $originalNotify.Found) {
    try {
        $existingCommand = @(ConvertFrom-NotifyLine $originalNotify.Line)
    } catch {
        if (-not $ReplaceUnparseableNotify) {
            throw 'The existing notify assignment is not a one-line JSON-compatible TOML string array. Back it up and edit it manually, or rerun with -ReplaceUnparseableNotify.'
        }
        $existingCommand = @()
    }

    if ($existingCommand.Count -gt 0) {
        $previousFlagIndex = [array]::IndexOf([object[]]$existingCommand, '--previous-notify')
        if ($previousFlagIndex -ge 0 -and $previousFlagIndex + 1 -lt $existingCommand.Count) {
            try {
                $nestedCommand = @(([string]$existingCommand[$previousFlagIndex + 1]) | ConvertFrom-Json)
            } catch {
                $nestedCommand = @()
            }

            if ($nestedCommand.Count -gt 0 -and (Test-ContainsInstalledNotifier $nestedCommand $InstallRoot)) {
                $existingCommand[$previousFlagIndex + 1] = ConvertTo-CommandJson $hookCommand
                $newNotifyCommand = $existingCommand
                $hookMode = 'existing-wrapper-upgraded'
                $isUpgrade = $true
            } elseif ($nestedCommand.Count -gt 0 -and (Test-ContainsLegacyNotifier $nestedCommand)) {
                $existingCommand[$previousFlagIndex + 1] = ConvertTo-CommandJson $hookCommand
                $newNotifyCommand = $existingCommand
                $hookMode = 'existing-wrapper-migrated'
            } elseif ($nestedCommand.Count -gt 0) {
                $previousNotifyCommand = $nestedCommand
                $existingCommand[$previousFlagIndex + 1] = ConvertTo-CommandJson $dispatchCommand
                $newNotifyCommand = $existingCommand
                $hookMode = 'existing-wrapper-chained'
            } else {
                $existingCommand[$previousFlagIndex + 1] = ConvertTo-CommandJson $hookCommand
                $newNotifyCommand = $existingCommand
                $hookMode = 'existing-wrapper-repaired'
            }
        } elseif (Test-ContainsInstalledNotifier $existingCommand $InstallRoot) {
            $newNotifyCommand = $existingCommand
            $hookMode = 'already-installed'
            $isUpgrade = $true
            $existingPreviousPath = Join-Path $InstallRoot 'previous-notify.json'
            if (Test-Path -LiteralPath $existingPreviousPath) {
                try { $previousNotifyCommand = @(Get-Content -LiteralPath $existingPreviousPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
            }
        } elseif (Test-ContainsLegacyNotifier $existingCommand) {
            $newNotifyCommand = $hookCommand
            $hookMode = 'legacy-replaced'
        } else {
            $previousNotifyCommand = $existingCommand
            $newNotifyCommand = $dispatchCommand
            $hookMode = 'top-level-chained'
        }
    }
}

$newNotifyLine = if ($SkipCodexHook) { '' } else { ConvertTo-NotifyLine $newNotifyCommand }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $InstallRoot 'backups'
$configBackup = ''
$hooksBackup = ''
$taskBackup = ''
$deploymentBackup = ''

if ($PSCmdlet.ShouldProcess($InstallRoot, 'Install Codex-to-Feishu notifier')) {
    Ensure-CfnDirectory $InstallRoot
    Ensure-CfnDirectory $backupRoot
    $managedNames = @('CodexFeishuNotify.psm1', 'notify.ps1', 'hook.ps1', 'drain.ps1', 'dispatch.ps1', 'settings.local.json', 'holidays.local.json', 'previous-notify.json', 'install-state.json')
    $existingManaged = @($managedNames | Where-Object { Test-Path -LiteralPath (Join-Path $InstallRoot $_) -PathType Leaf })
    if ($existingManaged.Count -gt 0) {
        $deploymentBackup = Join-Path $backupRoot "deployment-$stamp"
        Ensure-CfnDirectory $deploymentBackup
        foreach ($name in $existingManaged) {
            Copy-Item -LiteralPath (Join-Path $InstallRoot $name) -Destination (Join-Path $deploymentBackup $name) -Force
        }
    }
    foreach ($name in @('CodexFeishuNotify.psm1', 'notify.ps1', 'hook.ps1', 'drain.ps1', 'dispatch.ps1')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $InstallRoot $name) -Force
    }

    $settingsObject = [ordered]@{
        schema = 2
        transport = [ordered]@{
            type = 'lark-cli'
            enabled = (-not $NoFeishuNotifications)
            chat_id = $ChatId
            cli_path = $LarkCliPath
            channel_home = $LarkChannelHome
            profile = $LarkChannelProfile
            require_profile = (-not $NoLarkProfile)
            send_attempts_per_run = $SendAttemptsPerRun
            retry_delay_seconds = $RetryDelaySeconds
        }
        filters = [ordered]@{
            visible_threads_only = (-not $AllThreads)
            skip_bridge_origin = (-not $IncludeBridgeOrigin)
        }
        delivery = [ordered]@{
            start = $ScheduleStart
            end = $ScheduleEnd
            interval_minutes = $IntervalMinutes
            holiday_region = $resolvedHolidayRegion
            holiday_calendar = 'holidays.local.json'
            all_day_weekdays = @($AllDayWeekdays)
            max_queue_age_hours = $MaxQueueAgeHours
            sent_marker_retention_days = 90
            expired_item_retention_days = 7
        }
        lifecycle = [ordered]@{
            strict_completion_gate = (-not $NoStrictCompletionGate)
            completion_arm_ttl_minutes = 10
            notify_permission_requests = (-not $NoPermissionNotifications)
            waiting_state_ttl_hours = 24
            ready_state_ttl_hours = 720
        }
        desktop = [ordered]@{
            enabled = (-not $NoDesktopToast)
            only_when_codex_background = (-not $DesktopAlways)
            completion = (-not $NoDesktopCompletion)
            permission_request = (-not $NoDesktopPermissionRequest)
        }
        message = [ordered]@{
            format = $MessageFormat
            include_task_preview = (-not $NoTaskPreview)
            include_result_preview = (-not $NoResultPreview)
            include_permission_tool = [bool]$IncludePermissionTool
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($existingSettingsPath, ($settingsObject | ConvertTo-Json -Depth 5), $utf8NoBom)
    $suppressedCount = 0
    if ($NoFeishuNotifications) {
        $suppressed = Move-CfnPendingToSuppressed $InstallRoot 'installer-disabled'
        $suppressedCount = [int]$suppressed.Count
    }

    $installedHolidayPath = Join-Path $InstallRoot 'holidays.local.json'
    if ($null -ne $holidayCalendar) {
        Copy-Item -LiteralPath $HolidayCalendarPath -Destination $installedHolidayPath -Force
    } elseif (Test-Path -LiteralPath $installedHolidayPath) {
        Remove-Item -LiteralPath $installedHolidayPath -Force
    }

    $previousPath = Join-Path $InstallRoot 'previous-notify.json'
    if ($null -ne $previousNotifyCommand) {
        [System.IO.File]::WriteAllText($previousPath, (ConvertTo-CommandJson $previousNotifyCommand), $utf8NoBom)
    } elseif (Test-Path -LiteralPath $previousPath) {
        Remove-Item -LiteralPath $previousPath -Force
    }

    if (-not $SkipCodexHook) {
        if (Test-Path -LiteralPath $configPath) {
            $configBackup = Join-Path $backupRoot "config.toml.before-$stamp.bak"
            Copy-Item -LiteralPath $configPath -Destination $configBackup
        }
        $updatedConfig = Set-NotifyLine $configText $newNotifyLine
        [System.IO.File]::WriteAllText($configPath, $updatedConfig, $utf8NoBom)
    }

    if (-not $SkipLifecycleHooks) {
        if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
            $hooksBackup = Join-Path $backupRoot "hooks.json.before-$stamp.bak"
            Copy-Item -LiteralPath $hooksPath -Destination $hooksBackup
        }
        [System.IO.File]::WriteAllText($hooksPath, $updatedHooksText, $utf8NoBom)
        $persistedHooks = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($eventName in @('PermissionRequest', 'PostToolUse', 'UserPromptSubmit', 'SessionStart', 'Stop')) {
            $groups = @(Get-CfnProperty $persistedHooks.hooks $eventName @())
            $ourHandlers = @($groups | ForEach-Object { @(Get-CfnProperty $_ 'hooks' @()) } | Where-Object { Test-CfnLifecycleHandler $_ $InstallRoot })
            if ($ourHandlers.Count -ne 1) { throw "Lifecycle hook verification failed for $eventName." }
        }
    }

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        $taskBackup = Join-Path $backupRoot "$TaskName.before-$stamp.xml"
        [System.IO.File]::WriteAllText($taskBackup, (Export-ScheduledTask -TaskName $TaskName), [System.Text.Encoding]::Unicode)
    }

    $actionArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallRoot 'drain.ps1')
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $actionArguments -WorkingDirectory $InstallRoot
    $at = [datetime]::Today.Add($window.StartTime)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
    $repetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
        Interval = "PT${IntervalMinutes}M"
        Duration = $window.IsoDuration
        StopAtDurationEnd = $true
    }
    $trigger.Repetition = $repetition
    $allTriggers = @($trigger)
    $weeklyTriggerCount = 0
    $weeklyGapDurations = @()
    if ($AllDayWeekdays.Count -gt 0) {
        foreach ($gap in @(Get-CfnHolidayGapWindows ([datetime]::Today) $ScheduleStart $ScheduleEnd)) {
            if ($gap.Duration.TotalMinutes -lt $IntervalMinutes) { continue }
            $weeklyTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $AllDayWeekdays -At $gap.Start
            $weeklyRepetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
                Interval = "PT${IntervalMinutes}M"
                Duration = $gap.IsoDuration
                StopAtDurationEnd = $true
            }
            $weeklyTrigger.Repetition = $weeklyRepetition
            $allTriggers += $weeklyTrigger
            $weeklyGapDurations += $gap.IsoDuration
            $weeklyTriggerCount++
        }
    }
    $holidayTriggerCount = 0
    if ($null -ne $holidayCalendar) {
        $today = (Get-Date).Date
        foreach ($holiday in @($holidayCalendar.Holidays | Where-Object {
            $_.Date -ge $today -and $AllDayWeekdays -notcontains $_.Date.DayOfWeek.ToString()
        })) {
            foreach ($gap in @(Get-CfnHolidayGapWindows $holiday.Date $ScheduleStart $ScheduleEnd)) {
                if ($gap.Duration.TotalMinutes -lt $IntervalMinutes) { continue }
                $holidayTrigger = New-ScheduledTaskTrigger -Once -At $gap.Start
                $holidayRepetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
                    Interval = "PT${IntervalMinutes}M"
                    Duration = $gap.IsoDuration
                    StopAtDurationEnd = $true
                }
                $holidayTrigger.Repetition = $holidayRepetition
                $allTriggers += $holidayTrigger
                $holidayTriggerCount++
            }
        }
    }
    if ($allTriggers.Count -gt 47) {
        throw "The generated task has $($allTriggers.Count) persistent triggers; reduce the holiday calendar range or the number of all-day weekday gaps. One of the 48 task-trigger slots is reserved for temporary manual running."
    }
    $settings = New-ScheduledTaskSettingsSet -Hidden -DisallowDemandStart -StartWhenAvailable:$false `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $task = New-ScheduledTask -Action $action -Trigger $allTriggers -Settings $settings -Principal $principal `
        -Description 'Queues eligible Codex completions and delivers them to Feishu during the daily window, with optional all-day weekday and public-holiday extensions.'
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    if ($DisableScheduledTask) {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    } else {
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
    # Applying settings rebuilds the task and therefore ends any temporary
    # start/stop override. The newly saved schedule becomes authoritative.
    Clear-CfnManualDeliveryState $InstallRoot

    $persisted = Get-ScheduledTask -TaskName $TaskName
    $persistedDaily = @($persisted.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' })
    $persistedWeekly = @($persisted.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger' })
    $persistedHolidays = @($persisted.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' })
    $weekdayMasks = @{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }
    $expectedWeekdayMask = 0
    foreach ($weekday in $AllDayWeekdays) { $expectedWeekdayMask += [int]$weekdayMasks[$weekday] }
    $weeklyTriggersValid = ($persistedWeekly.Count -eq $weeklyTriggerCount)
    if ($weeklyTriggersValid) {
        foreach ($weekly in $persistedWeekly) {
            if ($weekly.WeeksInterval -ne 1 -or
                [int]$weekly.DaysOfWeek -ne $expectedWeekdayMask -or
                $weekly.Repetition.Interval -ne "PT${IntervalMinutes}M" -or
                -not $weekly.Repetition.StopAtDurationEnd) {
                $weeklyTriggersValid = $false
                break
            }
        }
    }
    $expectedWeeklyDurations = @($weeklyGapDurations | Sort-Object) -join '|'
    $actualWeeklyDurations = @($persistedWeekly | ForEach-Object { [string]$_.Repetition.Duration } | Sort-Object) -join '|'
    if ($expectedWeeklyDurations -ne $actualWeeklyDurations) { $weeklyTriggersValid = $false }
    if ($persistedDaily.Count -ne 1 -or
        $persistedDaily[0].DaysInterval -ne 1 -or
        $persistedDaily[0].Repetition.Interval -ne "PT${IntervalMinutes}M" -or
        $persistedDaily[0].Repetition.Duration -ne $window.IsoDuration -or
        -not $persistedDaily[0].Repetition.StopAtDurationEnd -or
        -not $weeklyTriggersValid -or
        $persistedHolidays.Count -ne $holidayTriggerCount -or
        $persisted.Settings.StartWhenAvailable -or
        $persisted.Settings.AllowDemandStart -or
        ($DisableScheduledTask -and $persisted.State -ne 'Disabled') -or
        (-not $DisableScheduledTask -and $persisted.State -eq 'Disabled')) {
        throw 'Scheduled task verification failed; inspect the task before relying on it.'
    }

    $priorOriginalNotify = [string](Get-CfnProperty $priorState 'original_notify_line' '')
    $priorConfigBackup = [string](Get-CfnProperty $priorState 'config_backup' '')
    $priorHooksBackup = [string](Get-CfnProperty $priorState 'hooks_backup' '')
    $priorTaskBackup = [string](Get-CfnProperty $priorState 'task_backup' '')
    $stateOriginalNotify = if ($isUpgrade -and $null -ne $priorState) { $priorOriginalNotify } elseif ($originalNotify.Found) { $originalNotify.Line } else { '' }
    $stateConfigBackup = if ($isUpgrade -and $priorConfigBackup) { $priorConfigBackup } else { $configBackup }
    $stateHooksBackup = if ($isUpgrade -and $priorHooksBackup) { $priorHooksBackup } else { $hooksBackup }
    $stateTaskBackup = if ($isUpgrade -and $priorTaskBackup) { $priorTaskBackup } else { $taskBackup }
    $state = [ordered]@{
        schema = 2
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        install_root = $InstallRoot
        task_name = $TaskName
        task_backup = $stateTaskBackup
        config_path = $configPath
        config_backup = $stateConfigBackup
        hooks_path = $hooksPath
        hooks_backup = $stateHooksBackup
        lifecycle_hooks = if ($SkipLifecycleHooks) { 'skipped' } else { 'installed' }
        deployment_backup = $deploymentBackup
        original_notify_line = $stateOriginalNotify
        installed_notify_line = $newNotifyLine
        hook_mode = if ($SkipCodexHook) { 'skipped' } else { $hookMode }
        holiday_region = $resolvedHolidayRegion
        holiday_calendar_source = $HolidayCalendarPath
        all_day_weekdays = @($AllDayWeekdays)
        weekly_trigger_count = $weeklyTriggerCount
        holiday_trigger_count = $holidayTriggerCount
        feishu_enabled = (-not $NoFeishuNotifications)
        schedule_enabled = (-not $DisableScheduledTask)
        suppressed_on_disable = $suppressedCount
    }
    [System.IO.File]::WriteAllText((Join-Path $InstallRoot 'install-state.json'), ($state | ConvertTo-Json -Depth 4), $utf8NoBom)

    Write-Host "Installed: $InstallRoot"
    Write-Host "Scheduled task: $TaskName ($ScheduleStart-$ScheduleEnd every $IntervalMinutes minute(s); weekly gaps=$weeklyTriggerCount for [$($AllDayWeekdays -join ',')]; holiday gaps=$holidayTriggerCount, region=$resolvedHolidayRegion)"
    Write-Host "Scheduled delivery: $(if ($DisableScheduledTask) { 'disabled' } else { 'enabled' })"
    Write-Host "Feishu notifications: $(if ($NoFeishuNotifications) { "disabled (suppressed=$suppressedCount)" } else { 'enabled' })"
    Write-Host "Codex notify hook: $($state.hook_mode)"
    Write-Host "Codex lifecycle hooks: $($state.lifecycle_hooks)"
    if ($deploymentBackup) { Write-Host "Previous deployment backup: $deploymentBackup" }
    Write-Host 'The task was registered but not started manually.'
}
