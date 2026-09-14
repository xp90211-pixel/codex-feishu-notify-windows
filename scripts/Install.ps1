[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ChatId = '',
    [string] $InstallRoot = '',
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
    [switch] $IncludeTaskPreview,
    [switch] $IncludeResultPreview,
    [switch] $ClearAllDayWeekdays,
    [switch] $SettingsOnly,
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
Import-Module (Join-Path $sourceRoot 'CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
if (-not $InstallRoot) { $InstallRoot = Join-Path (Get-CfnCodexHome) 'integrations\codex-feishu-notify' }

function Get-PowerShellExecutable {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { return $pwsh.Source }
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell) { return $windowsPowerShell }
    throw 'PowerShell executable was not found.'
}

function Get-NotifyLineRecord { param([string] $Text); return Get-CfnNotifyRecord $Text }
function ConvertFrom-NotifyLine { param([string] $Line); return @(ConvertFrom-CfnNotifyLine $Line) }

function ConvertTo-NotifyLine {
    param([object[]] $Command)
    return 'notify = ' + (ConvertTo-CfnTomlArray $Command)
}

function ConvertTo-CommandJson {
    param([object[]] $Command)
    return ConvertTo-Json -InputObject @($Command) -Compress -Depth 5
}

function Set-NotifyLine { param([string] $Text, [string] $NewLine); return Set-CfnNotifyLine $Text $NewLine }

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
    foreach ($name in @('notify.ps1', 'dispatch.ps1', 'notification-host.exe')) {
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
        async = $false
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

$existingRaw = $null
$existingResolved = $null
$existingSettingsPath = Join-Path $InstallRoot 'settings.local.json'
$existingSettingsText = if (Test-Path -LiteralPath $existingSettingsPath) { Read-CfnUtf8File $existingSettingsPath } else { '' }
if (Test-Path -LiteralPath $existingSettingsPath) {
    $existingRaw = Read-CfnUtf8File $existingSettingsPath | ConvertFrom-Json
    $existingResolved = Get-CfnSettings $InstallRoot
}
$priorStatePath = Join-Path $InstallRoot 'install-state.json'
$priorState = if (Test-Path -LiteralPath $priorStatePath) { Read-CfnUtf8File $priorStatePath | ConvertFrom-Json } else { $null }
if (-not $PSBoundParameters.ContainsKey('TaskName') -and $null -ne $priorState) {
    $TaskName = [string](Get-CfnProperty $priorState 'task_name' $TaskName)
}
if ($TaskName -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Task name must contain only letters, digits, dots, underscores, or hyphens.' }
$parameterProperties = @{
    ChatId = 'ChatId'; ScheduleStart = 'ScheduleStart'; ScheduleEnd = 'ScheduleEnd'
    IntervalMinutes = 'IntervalMinutes'; MaxQueueAgeHours = 'MaxQueueAgeHours'
    HolidayRegion = 'HolidayRegion'; AllDayWeekdays = 'AllDayWeekdays'
    LarkCliPath = 'LarkCliPath'; LarkChannelHome = 'LarkChannelHome'; LarkChannelProfile = 'LarkChannelProfile'
    MessageFormat = 'MessageFormat'; SendAttemptsPerRun = 'SendAttemptsPerRun'; RetryDelaySeconds = 'RetryDelaySeconds'
    IncludePermissionTool = 'IncludePermissionTool'
}
$negativeProperties = @{
    NoLarkProfile = 'RequireLarkProfile'; NoFeishuNotifications = 'FeishuEnabled'; DisableScheduledTask = 'ScheduleEnabled'
    AllThreads = 'VisibleThreadsOnly'; IncludeBridgeOrigin = 'SkipBridgeOrigin'
    NoTaskPreview = 'IncludeTaskPreview'; NoResultPreview = 'IncludeResultPreview'
    NoDesktopToast = 'DesktopEnabled'; DesktopAlways = 'DesktopOnlyWhenCodexBackground'
    NoDesktopCompletion = 'DesktopCompletion'; NoDesktopPermissionRequest = 'DesktopPermissionRequest'
    NoStrictCompletionGate = 'StrictCompletionGate'; NoPermissionNotifications = 'NotifyPermissionRequests'
}
if ($null -ne $existingResolved) {
    foreach ($name in $parameterProperties.Keys) {
        if (-not $PSBoundParameters.ContainsKey($name)) { $value = Get-CfnProperty $existingResolved $parameterProperties[$name]
            if ($name -eq 'HolidayRegion' -and $value -notin @('Auto', 'SG', 'CN', 'None')) { $value = 'Auto' }
            if ($name -eq 'AllDayWeekdays') { $value = [string[]]@($existingResolved.AllDayWeekdays) }
            Set-Variable -Name $name -Value $value -WhatIf:$false -Confirm:$false }
    }
    foreach ($name in $negativeProperties.Keys) {
        if (-not $PSBoundParameters.ContainsKey($name)) { Set-Variable -Name $name -Value (-not [bool](Get-CfnProperty $existingResolved $negativeProperties[$name])) -WhatIf:$false -Confirm:$false }
    }
    if (-not $PSBoundParameters.ContainsKey('HolidayCalendarPath') -and -not $PSBoundParameters.ContainsKey('HolidayRegion') -and
        $existingResolved.HolidayRegion -notin @('Auto', 'None', 'CN', 'SG')) {
        $HolidayCalendarPath = $existingResolved.HolidayCalendarPath
    }
} else {
    if (-not $PSBoundParameters.ContainsKey('NoTaskPreview')) { $NoTaskPreview = $true }
    if (-not $PSBoundParameters.ContainsKey('NoResultPreview')) { $NoResultPreview = $true }
}
if ($PSBoundParameters.ContainsKey('IncludeTaskPreview')) { $NoTaskPreview = -not $IncludeTaskPreview }
if ($PSBoundParameters.ContainsKey('IncludeResultPreview')) { $NoResultPreview = -not $IncludeResultPreview }
if ($ClearAllDayWeekdays) { $AllDayWeekdays = @() }
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask -and -not (Test-CfnTaskOwnership $existingTask $InstallRoot)) {
    throw 'The selected task belongs to another program or installation. Nothing was changed.'
}
if (-not $PSBoundParameters.ContainsKey('DisableScheduledTask') -and $existingTask) {
    $DisableScheduledTask = ([string]$existingTask.State -eq 'Disabled')
}
if ($SettingsOnly) {
    if ($null -eq $priorState -or -not $existingTask -or (Get-CfnProperty $priorState 'version' '') -ne '0.6.1') {
        throw 'Install or upgrade the notification runtime first with Install Notification; settings-only saving requires v0.6.1.'
    }
    $SkipCodexHook = $true
    $SkipLifecycleHooks = $true
}

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
            $legacyText = Get-Content -LiteralPath $legacyDrainPath -Raw -Encoding UTF8
            $legacyMatch = [regex]::Match($legacyText, '(?m)^\s*\$ChatId\s*=\s*(?<quote>[''"])(?<value>oc_[A-Za-z0-9_-]+)\k<quote>\s*$')
            if ($legacyMatch.Success) { $ChatId = $legacyMatch.Groups['value'].Value }
        } catch {}
    }
}
if (-not $NoFeishuNotifications -and ([string]::IsNullOrWhiteSpace($ChatId) -or $ChatId -match 'REPLACE')) {
    throw 'Provide the target Feishu chat id with -ChatId oc_xxx. It is saved only in the ignored local settings file.'
}

$codexRoot = Get-CfnCodexHome
$configPath = Join-Path $codexRoot 'config.toml'
if (-not (Test-Path -LiteralPath $configPath)) {
    $configText = ''
} else {
    $configText = Read-CfnUtf8File $configPath
}

$hookCommand = @((Join-Path $InstallRoot 'notification-host.exe'), 'notify')
$dispatchCommand = @((Join-Path $InstallRoot 'notification-host.exe'), 'dispatch')
$hooksPath = Join-Path $codexRoot 'hooks.json'
$hooksText = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
    Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8
} else { '' }
# Reuse the existing PowerShell hook shell instead of spawning another console.
$lifecycleCommand = "& '" + (Join-Path $InstallRoot 'hook.ps1').Replace("'", "''") + "'"
$updatedHooksText = if ($SkipLifecycleHooks) { '' } else {
    Get-CfnUpdatedHooksJson $hooksText $lifecycleCommand $InstallRoot
}
$originalNotify = if ($SkipCodexHook) { [pscustomobject]@{ Found = $false; Line = ''; Match = $null } } else { Get-NotifyLineRecord $configText }
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
            throw 'The root notify assignment is not a supported TOML string array. Review it or explicitly replace its entire value with -ReplaceUnparseableNotify.'
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
                $existingPreviousPath = Join-Path $InstallRoot 'previous-notify.json'
                if (Test-Path -LiteralPath $existingPreviousPath) {
                    $previousNotifyCommand = @(Read-CfnUtf8File $existingPreviousPath | ConvertFrom-Json)
                    $existingCommand[$previousFlagIndex + 1] = ConvertTo-CommandJson $dispatchCommand
                } else {
                    $existingCommand[$previousFlagIndex + 1] = ConvertTo-CommandJson $hookCommand
                }
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
            $newNotifyCommand = $hookCommand
            $hookMode = 'already-installed'
            $isUpgrade = $true
            $existingPreviousPath = Join-Path $InstallRoot 'previous-notify.json'
            if (Test-Path -LiteralPath $existingPreviousPath) {
                $previousNotifyCommand = @(Read-CfnUtf8File $existingPreviousPath | ConvertFrom-Json)
                $newNotifyCommand = $dispatchCommand
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
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Join-Path $InstallRoot 'backups'
$configBackup = ''
$hooksBackup = ''
$taskBackup = ''
$deploymentBackup = ''

    $action = New-ScheduledTaskAction -Execute (Join-Path $InstallRoot 'notification-host.exe') -Argument 'drain' -WorkingDirectory $InstallRoot
    $schedulePlan = @(Get-CfnSchedulePlan $ScheduleStart $ScheduleEnd $IntervalMinutes $AllDayWeekdays $holidayCalendar)
    $allTriggers = @(New-CfnScheduledTriggers $schedulePlan)
    $weeklyTriggerCount = @($schedulePlan | Where-Object Kind -eq 'Weekly').Count
    $holidayTriggerCount = @($schedulePlan | Where-Object Kind -eq 'Once').Count
    $weeklyGapDurations = @($schedulePlan | Where-Object Kind -eq 'Weekly' | ForEach-Object Duration)
    $settings = New-ScheduledTaskSettingsSet -Hidden -DisallowDemandStart -StartWhenAvailable:$false `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $task = New-ScheduledTask -Action $action -Trigger $allTriggers -Settings $settings -Principal $principal `
        -Description 'Queues eligible Codex completions and delivers them to Feishu during the daily window, with optional all-day weekday and public-holiday extensions.'

$updatedConfig = if ($SkipCodexHook) { $configText } else { Set-NotifyLine $configText $newNotifyLine }
$taskXmlBefore = if ($existingTask) { Export-ScheduledTask -TaskName $TaskName } else { '' }
$configExisted = Test-Path -LiteralPath $configPath
$hooksExisted = Test-Path -LiteralPath $hooksPath

if ($PSCmdlet.ShouldProcess($InstallRoot, 'Install or save Codex-to-Feishu notifier')) {
    Ensure-CfnDirectory $InstallRoot
    Ensure-CfnDirectory $backupRoot
    $managedNames = @('CodexFeishuNotify.psm1', 'notify.ps1', 'hook.ps1', 'drain.ps1', 'dispatch.ps1', 'notification-host.cs', 'notification-host.exe', 'settings.local.json', 'holidays.local.json', 'previous-notify.json', 'install-state.json', 'spool\state\runtime-control.json', 'spool\state\manual-delivery.json')
    $existingManaged = @($managedNames | Where-Object { Test-Path -LiteralPath (Join-Path $InstallRoot $_) -PathType Leaf })
    if ($existingManaged.Count -gt 0) {
        $deploymentBackup = Join-Path $backupRoot "deployment-$stamp"
        Ensure-CfnDirectory $deploymentBackup
        foreach ($name in $existingManaged) {
            Ensure-CfnDirectory (Split-Path -Parent (Join-Path $deploymentBackup $name))
            Copy-Item -LiteralPath (Join-Path $InstallRoot $name) -Destination (Join-Path $deploymentBackup $name) -Force
        }
    }
    $stateLock = Enter-CfnMutex $InstallRoot 'state' 5000
    if ($null -eq $stateLock) { throw 'Notification state is busy; no files were changed.' }
    # Preflight used snapshots. If another settings/control operation won the
    # race, refuse this stale deployment rather than overwriting its changes.
    try {
        foreach ($entry in @(@($configPath, $configText), @($hooksPath, $hooksText), @($existingSettingsPath, $existingSettingsText))) {
            $currentText = if (Test-Path -LiteralPath $entry[0]) { Read-CfnUtf8File $entry[0] } else { '' }
            if ($currentText -cne $entry[1]) { throw 'Configuration changed during preflight; retry. Nothing was overwritten.' }
        }
        foreach ($name in $existingManaged) {
            if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $name)) -or
                (Get-FileHash -LiteralPath (Join-Path $InstallRoot $name)).Hash -cne
                (Get-FileHash -LiteralPath (Join-Path $deploymentBackup $name)).Hash) {
                throw 'Managed state changed during backup; retry. Nothing was overwritten.'
            }
        }
    } catch { Exit-CfnMutex $stateLock; throw }
    $taskTouched = $false
    $configTouched = $false
    $hooksTouched = $false
    try {
    if (-not $SettingsOnly) {
    foreach ($name in @('CodexFeishuNotify.psm1', 'notify.ps1', 'hook.ps1', 'drain.ps1', 'dispatch.ps1', 'notification-host.cs')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $InstallRoot $name) -Force
    }
    New-CfnNotificationHost -SourcePath (Join-Path $InstallRoot 'notification-host.cs') -OutputPath (Join-Path $InstallRoot 'notification-host.exe')

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
            timeout_seconds = 30
        }
        filters = [ordered]@{
            visible_threads_only = (-not $AllThreads)
            skip_bridge_origin = (-not $IncludeBridgeOrigin)
        }
        delivery = [ordered]@{
            enabled = (-not $DisableScheduledTask)
            start = $ScheduleStart
            end = $ScheduleEnd
            interval_minutes = $IntervalMinutes
            holiday_region = $resolvedHolidayRegion
            holiday_calendar = 'holidays.local.json'
            all_day_weekdays = @($AllDayWeekdays)
            max_queue_age_hours = $MaxQueueAgeHours
            sent_marker_retention_days = 90
            expired_item_retention_days = 7
            suppressed_item_retention_days = 7
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

    $generated = $settingsObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $settingsObject = $settingsObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    if ($null -ne $existingRaw) {
        Merge-CfnObject $settingsObject $existingRaw
        # Parameter-backed fields already inherited old values unless explicitly changed.
        foreach ($section in @('transport', 'filters', 'desktop', 'message')) {
            foreach ($p in @($generated.$section.PSObject.Properties)) {
                if ($p.Name -eq 'timeout_seconds') { continue }
                $settingsObject.$section | Add-Member NoteProperty $p.Name $p.Value -Force
            }
        }
        foreach ($name in @('enabled', 'start', 'end', 'interval_minutes', 'holiday_region', 'holiday_calendar', 'all_day_weekdays', 'max_queue_age_hours')) {
            $settingsObject.delivery | Add-Member NoteProperty $name $generated.delivery.$name -Force
        }
        foreach ($name in @('strict_completion_gate', 'notify_permission_requests')) {
            $settingsObject.lifecycle | Add-Member NoteProperty $name $generated.lifecycle.$name -Force
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    Write-CfnJsonAtomic $existingSettingsPath $settingsObject
    [void](Get-CfnSettings $InstallRoot)
    $suppressedCount = 0


    $installedHolidayPath = Join-Path $InstallRoot 'holidays.local.json'
    if ($null -ne $holidayCalendar) {
        if ([IO.Path]::GetFullPath($HolidayCalendarPath) -ine [IO.Path]::GetFullPath($installedHolidayPath)) {
            Copy-Item -LiteralPath $HolidayCalendarPath -Destination $installedHolidayPath -Force
        }
    } elseif (Test-Path -LiteralPath $installedHolidayPath) {
        Remove-Item -LiteralPath $installedHolidayPath -Force
    }

    if (-not $SettingsOnly) {
    $previousPath = Join-Path $InstallRoot 'previous-notify.json'
    if ($null -ne $previousNotifyCommand) {
        [System.IO.File]::WriteAllText($previousPath, (ConvertTo-CommandJson $previousNotifyCommand), $utf8NoBom)
    } elseif (Test-Path -LiteralPath $previousPath) {
        Remove-Item -LiteralPath $previousPath -Force
    }

    }
    if (-not $SkipCodexHook) {
        if (Test-Path -LiteralPath $configPath) {
            $configBackup = Join-Path $backupRoot "config.toml.before-$stamp.bak"
            Copy-Item -LiteralPath $configPath -Destination $configBackup
        }
        Ensure-CfnDirectory $codexRoot
        $configTouched = $true
        [System.IO.File]::WriteAllText($configPath, $updatedConfig, $utf8NoBom)
    }

    if (-not $SkipLifecycleHooks) {
        if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
            $hooksBackup = Join-Path $backupRoot "hooks.json.before-$stamp.bak"
            Copy-Item -LiteralPath $hooksPath -Destination $hooksBackup
        }
        Ensure-CfnDirectory $codexRoot
        $hooksTouched = $true
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

    $scheduleChanged = -not $SettingsOnly
    if ($SettingsOnly) {
        $beforeDelivery = Get-CfnProperty $existingRaw 'delivery' $null
        $scheduleChanged = $false
        foreach ($name in @('start', 'end', 'interval_minutes', 'holiday_region', 'holiday_calendar', 'all_day_weekdays')) {
            if ((Get-CfnProperty $beforeDelivery $name | ConvertTo-Json -Compress) -cne ($settingsObject.delivery.$name | ConvertTo-Json -Compress)) { $scheduleChanged = $true }
        }
        if ($null -ne $holidayCalendar -and (Test-Path -LiteralPath (Join-Path $deploymentBackup 'holidays.local.json'))) {
            $scheduleChanged = $scheduleChanged -or (Get-FileHash (Join-Path $deploymentBackup 'holidays.local.json')).Hash -ne (Get-FileHash $installedHolidayPath).Hash
        }
    }
    $scheduleChanged = $scheduleChanged -or ([bool]($existingTask.State -eq 'Disabled') -ne [bool]$DisableScheduledTask)
    if ($scheduleChanged) {
    $taskTouched = $true
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    if ($DisableScheduledTask) {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    } else {
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
    # Applying settings rebuilds the task and therefore ends any temporary
    # start/stop override. The newly saved schedule becomes authoritative.
    Clear-CfnManualDeliveryState $InstallRoot

    }
    Write-CfnJsonAtomic (Join-Path $InstallRoot 'spool\state\runtime-control.json') @{ enabled = (-not $DisableScheduledTask); changed_at = [datetimeoffset]::UtcNow.ToString('o') }
    $persisted = Get-ScheduledTask -TaskName $TaskName
    if ($scheduleChanged -and (-not (Test-CfnScheduleTriggers $persisted $schedulePlan) -or
        $persisted.Settings.AllowDemandStart -or $persisted.Settings.StartWhenAvailable -or
        [bool]($persisted.State -eq 'Disabled') -ne [bool]$DisableScheduledTask)) {
        throw 'Scheduled task verification failed.'
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
        version = '0.6.1'
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
    if ($SettingsOnly) {
        foreach ($name in @('installed_at', 'task_backup', 'config_path', 'config_backup', 'hooks_path', 'hooks_backup', 'lifecycle_hooks', 'original_notify_line', 'installed_notify_line', 'hook_mode')) {
            $state[$name] = Get-CfnProperty $priorState $name ''
        }
    }
    Write-CfnJsonAtomic (Join-Path $InstallRoot 'install-state.json') $state
    } catch {
        $failure = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        foreach ($name in $managedNames) {
            try {
                $destination = Join-Path $InstallRoot $name
                if ($existingManaged -contains $name) {
                    Ensure-CfnDirectory (Split-Path -Parent $destination)
                    Copy-Item -LiteralPath (Join-Path $deploymentBackup $name) -Destination $destination -Force
                } elseif (Test-Path -LiteralPath $destination -PathType Leaf) { Remove-Item -LiteralPath $destination -Force }
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        foreach ($entry in @(@($configTouched, $configExisted, $configPath, $configBackup), @($hooksTouched, $hooksExisted, $hooksPath, $hooksBackup))) {
            if (-not $entry[0]) { continue }
            try {
                if ($entry[1]) { Copy-Item -LiteralPath $entry[3] -Destination $entry[2] -Force }
                elseif (Test-Path -LiteralPath $entry[2]) { Remove-Item -LiteralPath $entry[2] -Force }
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($taskTouched) {
            try {
                if ($taskXmlBefore) { Register-ScheduledTask -TaskName $TaskName -Xml $taskXmlBefore -Force | Out-Null }
                elseif (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count) { throw "Installation failed: $($failure.Exception.Message). Rollback needs attention: $($rollbackErrors -join '; '). Backups: $backupRoot" }
        throw "Installation failed and previous files/configuration/task were restored: $($failure.Exception.Message)"
    } finally { Exit-CfnMutex $stateLock }
    if ($NoFeishuNotifications) {
        try { $suppressedCount = [int](Move-CfnPendingToSuppressed $InstallRoot 'installer-disabled').Count }
        catch { Write-Warning 'Notifications are disabled; some pending files could not be moved to suppressed.' }
    }

    Write-Host "Installed: $InstallRoot"
    Write-Host "Scheduled task: $TaskName ($ScheduleStart-$ScheduleEnd every $IntervalMinutes minute(s); weekly gaps=$weeklyTriggerCount for [$($AllDayWeekdays -join ',')]; holiday gaps=$holidayTriggerCount, region=$resolvedHolidayRegion)"
    Write-Host "Scheduled delivery: $(if ($DisableScheduledTask) { 'disabled' } else { 'enabled' })"
    Write-Host "Feishu notifications: $(if ($NoFeishuNotifications) { "disabled (suppressed=$suppressedCount)" } else { 'enabled' })"
    Write-Host "Codex notify hook: $($state.hook_mode)"
    Write-Host "Codex lifecycle hooks: $($state.lifecycle_hooks)"
    if ($deploymentBackup) { Write-Host "Previous deployment backup: $deploymentBackup" }
    Write-Host 'The task was registered but not started manually.'
}
