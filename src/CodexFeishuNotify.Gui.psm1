Set-StrictMode -Version 2.0

$coreModulePath = Join-Path $PSScriptRoot 'CodexFeishuNotify.psm1'
if (-not (Test-Path -LiteralPath $coreModulePath -PathType Leaf)) {
    throw "Core module was not found: $coreModulePath"
}
Import-Module $coreModulePath -Force -DisableNameChecking
$script:CfnManualTriggerId = 'CodexFeishuNotify.ManualOverride'

function Get-CfnGuiTask {
    param([AllowEmptyString()] [string] $TaskName = '')

    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    if ($TaskName) {
        return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    foreach ($candidate in @('Codex.LarkNotify.codex', 'Codex.FeishuNotify')) {
        $task = Get-ScheduledTask -TaskName $candidate -ErrorAction SilentlyContinue
        if ($task) { return $task }
    }
    return $null
}

function Get-CfnGuiTaskInstallRoot {
    param([AllowNull()] $Task)

    if ($null -eq $Task) { return '' }
    foreach ($action in @($Task.Actions)) {
        $arguments = [string]$action.Arguments
        $match = [regex]::Match($arguments, '(?i)(?:^|\s)-File\s+"(?<path>[^"]+)"')
        if (-not $match.Success) {
            $match = [regex]::Match($arguments, '(?i)(?:^|\s)-File\s+(?<path>\S+)')
        }
        if ($match.Success) {
            $scriptPath = Resolve-CfnPath $match.Groups['path'].Value
            if ([System.IO.Path]::GetFileName($scriptPath) -ieq 'drain.ps1') {
                return Split-Path -Parent $scriptPath
            }
        }
    }
    return ''
}

function Get-CfnGuiTarget {
    param(
        [AllowEmptyString()] [string] $InstallRoot = '',
        [AllowEmptyString()] [string] $TaskName = ''
    )

    $task = Get-CfnGuiTask $TaskName
    if (-not $TaskName) {
        if ($task) {
            $TaskName = [string]$task.TaskName
        } else {
            $TaskName = 'Codex.LarkNotify.codex'
        }
    }

    if (-not $InstallRoot) { $InstallRoot = Get-CfnGuiTaskInstallRoot $task }
    if (-not $InstallRoot) {
        $legacyRoot = Join-Path $env:USERPROFILE '.codex\integrations\lark-channel-notify'
        $portableRoot = Join-Path $env:USERPROFILE '.codex\integrations\codex-feishu-notify'
        if ($TaskName -eq 'Codex.LarkNotify.codex' -and (Test-Path -LiteralPath $legacyRoot)) {
            $InstallRoot = $legacyRoot
        } elseif (Test-Path -LiteralPath $portableRoot) {
            $InstallRoot = $portableRoot
        } else {
            $InstallRoot = $portableRoot
        }
    }

    $InstallRoot = [System.IO.Path]::GetFullPath((Resolve-CfnPath $InstallRoot))
    [pscustomobject]@{
        InstallRoot = $InstallRoot
        TaskName = $TaskName
        TaskExists = [bool]$task
    }
}

function Get-CfnGuiAssignedValue {
    param(
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $Name,
        [switch] $EnvironmentVariable
    )

    $escaped = [regex]::Escape($Name)
    $prefix = if ($EnvironmentVariable) { '\$env:' } else { '\$' }
    $pattern = '(?m)^\s*' + $prefix + $escaped + '\s*=\s*(?<quote>[''"])(?<value>.*?)\k<quote>\s*$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups['value'].Value }
    return ''
}

function Get-CfnGuiTaskSchedule {
    param([AllowEmptyString()] [string] $TaskName = '')

    $result = [ordered]@{
        Start = '18:40'
        End = '02:00'
        IntervalMinutes = 1
    }
    $task = Get-CfnGuiTask $TaskName
    if (-not $task) { return [pscustomobject]$result }
    $daily = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' }) |
        Select-Object -First 1
    if (-not $daily) { return [pscustomobject]$result }

    try {
        $startDate = [datetime]$daily.StartBoundary
        $duration = [System.Xml.XmlConvert]::ToTimeSpan([string]$daily.Repetition.Duration)
        $interval = [System.Xml.XmlConvert]::ToTimeSpan([string]$daily.Repetition.Interval)
        $result.Start = $startDate.ToString('HH:mm')
        $result.End = ([datetime]::Today.Add($startDate.TimeOfDay).Add($duration)).ToString('HH:mm')
        $result.IntervalMinutes = [int]$interval.TotalMinutes
    } catch {}
    return [pscustomobject]$result
}

function Get-CfnGuiLarkCliResolution {
    param([AllowEmptyString()] [string] $ConfiguredPath = '')

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $resolvedExplicit = Resolve-CfnPath $ConfiguredPath
        return [pscustomobject]@{
            Mode = 'explicit'
            Found = [bool]($resolvedExplicit -and (Test-Path -LiteralPath $resolvedExplicit -PathType Leaf))
            Path = [string]$resolvedExplicit
        }
    }

    $autoPath = [string](Find-CfnLarkCli)
    return [pscustomobject]@{
        Mode = 'auto'
        Found = [bool]$autoPath
        Path = $autoPath
    }
}

function Get-CfnGuiLarkProfiles {
    param([AllowEmptyString()] [string] $ChannelHome = '')

    $resolvedHome = Resolve-CfnPath $ChannelHome
    if ([string]::IsNullOrWhiteSpace($resolvedHome)) { return @() }
    $profilesRoot = Join-Path $resolvedHome 'profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) { return @() }

    return @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { $_.Name })
}

function Get-CfnGuiModel {
    param(
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [string] $TaskName
    )

    $schedule = Get-CfnGuiTaskSchedule $TaskName
    $task = Get-CfnGuiTask $TaskName
    $settingsPath = Join-Path $InstallRoot 'settings.local.json'
    $model = [ordered]@{
        InstallRoot = $InstallRoot
        TaskName = $TaskName
        Source = 'defaults'
        SourcePath = $settingsPath
        ChatId = ''
        LarkCliPath = ''
        ResolvedLarkCliPath = [string](Get-CfnGuiLarkCliResolution).Path
        LarkChannelHome = (Join-Path $env:USERPROFILE '.lark-channel')
        LarkChannelProfile = 'codex'
        RequireLarkProfile = $true
        FeishuEnabled = $true
        ScheduleEnabled = if ($task) { [string]$task.State -ne 'Disabled' } else { $true }
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
        ScheduleStart = $schedule.Start
        ScheduleEnd = $schedule.End
        IntervalMinutes = $schedule.IntervalMinutes
        HolidayRegion = 'None'
        HolidayCalendarPath = ''
        AllDayWeekdays = @()
        MaxQueueAgeHours = 24
        IncludeTaskPreview = $true
        IncludeResultPreview = $true
        IncludePermissionTool = $false
        MessageFormat = 'card'
    }

    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $settings = Get-CfnSettings $InstallRoot
        $model.Source = 'managed'
        $model.ChatId = $settings.ChatId
        $model.LarkCliPath = $settings.LarkCliPath
        $model.LarkChannelHome = $settings.LarkChannelHome
        $model.LarkChannelProfile = $settings.LarkChannelProfile
        $model.RequireLarkProfile = $settings.RequireLarkProfile
        $model.FeishuEnabled = $settings.FeishuEnabled
        $model.SendAttemptsPerRun = $settings.SendAttemptsPerRun
        $model.RetryDelaySeconds = $settings.RetryDelaySeconds
        $model.VisibleThreadsOnly = $settings.VisibleThreadsOnly
        $model.SkipBridgeOrigin = $settings.SkipBridgeOrigin
        $model.StrictCompletionGate = $settings.StrictCompletionGate
        $model.NotifyPermissionRequests = $settings.NotifyPermissionRequests
        $model.DesktopEnabled = $settings.DesktopEnabled
        $model.DesktopOnlyWhenCodexBackground = $settings.DesktopOnlyWhenCodexBackground
        $model.DesktopCompletion = $settings.DesktopCompletion
        $model.DesktopPermissionRequest = $settings.DesktopPermissionRequest
        $model.ScheduleStart = $settings.ScheduleStart
        $model.ScheduleEnd = $settings.ScheduleEnd
        $model.IntervalMinutes = $settings.IntervalMinutes
        $model.AllDayWeekdays = @($settings.AllDayWeekdays)
        $model.MaxQueueAgeHours = $settings.MaxQueueAgeHours
        $model.IncludeTaskPreview = $settings.IncludeTaskPreview
        $model.IncludeResultPreview = $settings.IncludeResultPreview
        $model.IncludePermissionTool = $settings.IncludePermissionTool
        $model.MessageFormat = $settings.MessageFormat
        $model.ResolvedLarkCliPath = [string](Get-CfnGuiLarkCliResolution $model.LarkCliPath).Path

        if ($settings.HolidayRegion -in @('Auto', 'SG', 'CN', 'None')) {
            $model.HolidayRegion = $settings.HolidayRegion
        } else {
            $model.HolidayRegion = 'Custom'
            $model.HolidayCalendarPath = $settings.HolidayCalendarPath
        }

        $statePath = Join-Path $InstallRoot 'install-state.json'
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $calendarSource = Resolve-CfnPath ([string](Get-CfnProperty $state 'holiday_calendar_source' ''))
                if ($calendarSource -and -not ($calendarSource -match '(?i)[\\/]config[\\/]holidays\.(sg|cn\.2026)\.json$')) {
                    $model.HolidayRegion = 'Custom'
                    $model.HolidayCalendarPath = if (Test-Path -LiteralPath $calendarSource) {
                        [System.IO.Path]::GetFullPath($calendarSource)
                    } else {
                        $settings.HolidayCalendarPath
                    }
                }
            } catch {}
        }
        return [pscustomobject]$model
    }

    $drainPath = Join-Path $InstallRoot 'drain.ps1'
    if (Test-Path -LiteralPath $drainPath -PathType Leaf) {
        $legacyText = Get-Content -LiteralPath $drainPath -Raw
        $model.Source = 'legacy'
        $model.SourcePath = $drainPath
        $model.ChatId = Get-CfnGuiAssignedValue $legacyText 'ChatId'
        $model.LarkCliPath = Get-CfnGuiAssignedValue $legacyText 'preferred'
        $legacyHome = Get-CfnGuiAssignedValue $legacyText 'LARK_CHANNEL_HOME' -EnvironmentVariable
        $legacyProfile = Get-CfnGuiAssignedValue $legacyText 'LARK_CHANNEL_PROFILE' -EnvironmentVariable
        if ($legacyHome) { $model.LarkChannelHome = $legacyHome }
        if ($legacyProfile) { $model.LarkChannelProfile = $legacyProfile }

        $calendarPath = Join-Path $InstallRoot 'holidays.local.json'
        if (Test-Path -LiteralPath $calendarPath -PathType Leaf) {
            try {
                $calendar = Get-CfnHolidayCalendar $calendarPath
                if ($calendar.Region -in @('SG', 'CN')) {
                    $model.HolidayRegion = $calendar.Region
                } else {
                    $model.HolidayRegion = 'Custom'
                    $model.HolidayCalendarPath = $calendarPath
                }
            } catch {
                $model.HolidayRegion = 'Custom'
                $model.HolidayCalendarPath = $calendarPath
            }
        }
    }
    $model.ResolvedLarkCliPath = [string](Get-CfnGuiLarkCliResolution $model.LarkCliPath).Path
    return [pscustomobject]$model
}

function Test-CfnGuiModel {
    param([Parameter(Mandatory = $true)] $Model)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $window = $null

    if ([string]::IsNullOrWhiteSpace([string]$Model.TaskName)) {
        $errors.Add('计划任务名称不能为空。')
    }
    if ([string]::IsNullOrWhiteSpace([string]$Model.InstallRoot)) {
        $errors.Add('安装目录不能为空。')
    }
    if ([string]$Model.ChatId -notmatch '^oc_[A-Za-z0-9_-]{8,}$') {
        $errors.Add('飞书会话 ID 应为 oc_ 开头的有效值。')
    }

    try {
        $window = Get-CfnScheduleWindow ([string]$Model.ScheduleStart) ([string]$Model.ScheduleEnd)
        if ([int]$Model.IntervalMinutes -lt 1 -or [int]$Model.IntervalMinutes -gt 60) {
            $errors.Add('检查间隔必须为 1 到 60 分钟。')
        } elseif ($window.Duration.TotalMinutes -lt [int]$Model.IntervalMinutes) {
            $errors.Add('检查间隔不能超过运行时间窗。')
        }
    } catch {
        $errors.Add($_.Exception.Message)
    }

    if ([int]$Model.MaxQueueAgeHours -lt 1 -or [int]$Model.MaxQueueAgeHours -gt 720) {
        $errors.Add('队列最长保留时间必须为 1 到 720 小时。')
    }
    if ([int]$Model.SendAttemptsPerRun -lt 1 -or [int]$Model.SendAttemptsPerRun -gt 5) {
        $errors.Add('单次发送尝试次数必须为 1 到 5。')
    }
    if ([int]$Model.RetryDelaySeconds -lt 0 -or [int]$Model.RetryDelaySeconds -gt 30) {
        $errors.Add('发送重试间隔必须为 0 到 30 秒。')
    }
    if ([string]$Model.MessageFormat -notin @('card', 'text')) {
        $errors.Add('飞书消息格式必须为 card 或 text。')
    }
    if ([string]$Model.HolidayRegion -notin @('Auto', 'SG', 'CN', 'None', 'Custom')) {
        $errors.Add('节假日模式无效。')
    }
    if ([string]$Model.HolidayRegion -eq 'Custom') {
        $calendarPath = Resolve-CfnPath ([string]$Model.HolidayCalendarPath)
        if (-not (Test-Path -LiteralPath $calendarPath -PathType Leaf)) {
            $errors.Add('自定义节假日日历不存在。')
        } else {
            try { [void](Get-CfnHolidayCalendar $calendarPath) } catch { $errors.Add($_.Exception.Message) }
        }
    }
    $weekdayOrder = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    $weekdayProperty = $Model.PSObject.Properties['AllDayWeekdays']
    $selectedWeekdays = if ($null -ne $weekdayProperty) { @($weekdayProperty.Value) } else { @() }
    $invalidWeekdays = @($selectedWeekdays | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -notin $weekdayOrder })
    if ($invalidWeekdays.Count -gt 0) {
        $errors.Add("全天运行日包含无效值：$($invalidWeekdays -join '、')。")
    }
    if ([string]$Model.LarkCliPath) {
        $cliPath = Resolve-CfnPath ([string]$Model.LarkCliPath)
        if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
            $errors.Add('指定的 lark-cli 路径不存在。')
        }
    } elseif (-not (Find-CfnLarkCli)) {
        $errors.Add('未找到 lark-cli；请指定可执行文件路径。')
    }

    if ([bool]$Model.RequireLarkProfile) {
        $channelHome = Resolve-CfnPath ([string]$Model.LarkChannelHome)
        if ([string]::IsNullOrWhiteSpace($channelHome) -or [string]::IsNullOrWhiteSpace([string]$Model.LarkChannelProfile)) {
            $errors.Add('启用 Lark profile 时必须填写配置根目录和 profile。')
        } else {
            $profileRoot = Join-Path $channelHome ('profiles\{0}' -f [string]$Model.LarkChannelProfile)
            if (-not (Test-Path -LiteralPath (Join-Path $profileRoot 'lark-cli-source\config.json')) -or
                -not (Test-Path -LiteralPath (Join-Path $profileRoot 'lark-cli'))) {
                $warnings.Add("Lark profile 尚未就绪：$profileRoot")
            }
        }
    }

    [pscustomobject]@{
        Valid = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
        Warnings = $warnings.ToArray()
        Window = $window
    }
}

function Get-CfnGuiInstallParameters {
    param([Parameter(Mandatory = $true)] $Model)

    $weekdayProperty = $Model.PSObject.Properties['AllDayWeekdays']
    [string[]] $allDayWeekdays = @()
    if ($null -ne $weekdayProperty) {
        $allDayWeekdays = [string[]]@($weekdayProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $parameters = @{
        ChatId = [string]$Model.ChatId
        InstallRoot = [string]$Model.InstallRoot
        TaskName = [string]$Model.TaskName
        ScheduleStart = [string]$Model.ScheduleStart
        ScheduleEnd = [string]$Model.ScheduleEnd
        IntervalMinutes = [int]$Model.IntervalMinutes
        MaxQueueAgeHours = [int]$Model.MaxQueueAgeHours
        LarkCliPath = [string]$Model.LarkCliPath
        LarkChannelHome = [string]$Model.LarkChannelHome
        LarkChannelProfile = [string]$Model.LarkChannelProfile
        SendAttemptsPerRun = [int]$Model.SendAttemptsPerRun
        RetryDelaySeconds = [int]$Model.RetryDelaySeconds
        NoLarkProfile = (-not [bool]$Model.RequireLarkProfile)
        NoFeishuNotifications = (-not [bool]$Model.FeishuEnabled)
        DisableScheduledTask = (-not [bool]$Model.ScheduleEnabled)
        AllThreads = (-not [bool]$Model.VisibleThreadsOnly)
        IncludeBridgeOrigin = (-not [bool]$Model.SkipBridgeOrigin)
        NoTaskPreview = (-not [bool]$Model.IncludeTaskPreview)
        NoResultPreview = (-not [bool]$Model.IncludeResultPreview)
        IncludePermissionTool = [bool]$Model.IncludePermissionTool
        MessageFormat = [string]$Model.MessageFormat
        NoDesktopToast = (-not [bool]$Model.DesktopEnabled)
        DesktopAlways = (-not [bool]$Model.DesktopOnlyWhenCodexBackground)
        NoDesktopCompletion = (-not [bool]$Model.DesktopCompletion)
        NoDesktopPermissionRequest = (-not [bool]$Model.DesktopPermissionRequest)
        NoStrictCompletionGate = (-not [bool]$Model.StrictCompletionGate)
        NoPermissionNotifications = (-not [bool]$Model.NotifyPermissionRequests)
    }
    # An empty selection can collapse to $null while flowing through PowerShell
    # expressions. Omit this optional parameter when no weekday is selected so
    # Install.ps1 receives its declared @() default instead of failing ValidateSet.
    if ($allDayWeekdays.Count -gt 0) {
        $parameters.AllDayWeekdays = [string[]]$allDayWeekdays
    }
    if ([string]$Model.HolidayRegion -eq 'Custom') {
        $parameters.HolidayRegion = 'Auto'
        $parameters.HolidayCalendarPath = [string]$Model.HolidayCalendarPath
    } else {
        $parameters.HolidayRegion = [string]$Model.HolidayRegion
    }
    return $parameters
}

function Set-CfnGuiFeishuEnabled {
    param(
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [bool] $Enabled
    )

    $settingsPath = Join-Path $InstallRoot 'settings.local.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw "受管配置不存在：$settingsPath"
    }
    $settingsDocument = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $transport = Get-CfnProperty $settingsDocument 'transport' $null
    if ($null -eq $transport) {
        $transport = New-Object psobject
        $settingsDocument | Add-Member -MemberType NoteProperty -Name transport -Value $transport -Force
    }
    $transport | Add-Member -MemberType NoteProperty -Name enabled -Value $Enabled -Force

    $backupRoot = Join-Path $InstallRoot 'backups'
    Ensure-CfnDirectory $backupRoot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $backupPath = Join-Path $backupRoot "settings.local.json.before-feishu-toggle-$stamp.bak"
    Copy-Item -LiteralPath $settingsPath -Destination $backupPath

    $tempPath = "$settingsPath.$PID.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tempPath, ($settingsDocument | ConvertTo-Json -Depth 8), $utf8NoBom)
        Move-Item -LiteralPath $tempPath -Destination $settingsPath -Force
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }

    $suppressedCount = 0
    if (-not $Enabled) {
        $suppressed = Move-CfnPendingToSuppressed $InstallRoot 'gui-manual-disable'
        $suppressedCount = [int]$suppressed.Count
    }
    Write-CfnLog $InstallRoot 'settings' $(if ($Enabled) { 'feishu_enabled' } else { 'feishu_disabled' }) '' "suppressed=$suppressedCount"
    return [pscustomobject]@{
        Enabled = $Enabled
        BackupPath = $backupPath
        SuppressedCount = $suppressedCount
    }
}

function Get-CfnGuiPowerShellExecutable {
    $current = try { (Get-Process -Id $PID -ErrorAction Stop).Path } catch { '' }
    if ($current -and (Test-Path -LiteralPath $current -PathType Leaf)) { return $current }
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { return $pwsh.Source }
    return (Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
}

function Set-CfnGuiManualTrigger {
    param(
        [Parameter(Mandatory = $true)] [string] $TaskName,
        [Parameter(Mandatory = $true)] [bool] $Enabled,
        [datetime] $ExpiresAt = (Get-Date).AddMinutes(1),
        [ValidateRange(1, 60)] [int] $IntervalMinutes = 1,
        [datetime] $Now = (Get-Date)
    )

    $task = Get-CfnGuiTask $TaskName
    if (-not $task) { throw "计划任务不存在：$TaskName" }
    $baseTriggers = @($task.Triggers | Where-Object { [string]$_.Id -ne $script:CfnManualTriggerId })
    $hadManualTrigger = ($baseTriggers.Count -ne @($task.Triggers).Count)
    if (-not $Enabled) {
        if ($hadManualTrigger) {
            Set-ScheduledTask -TaskName $TaskName -Trigger $baseTriggers -ErrorAction Stop | Out-Null
        }
        return $false
    }

    if ($baseTriggers.Count -ge 48) {
        throw '计划任务已有 48 个触发器，无法增加临时运行触发器；请缩短自定义节假日日历范围后重新应用设置。'
    }
    $firstRun = $Now.AddMinutes($IntervalMinutes)
    if ($firstRun -ge $ExpiresAt) {
        if ($hadManualTrigger) {
            Set-ScheduledTask -TaskName $TaskName -Trigger $baseTriggers -ErrorAction Stop | Out-Null
        }
        return $false
    }
    $duration = $ExpiresAt - $firstRun
    if ($duration -lt [timespan]::FromMinutes($IntervalMinutes)) {
        if ($hadManualTrigger) {
            Set-ScheduledTask -TaskName $TaskName -Trigger $baseTriggers -ErrorAction Stop | Out-Null
        }
        return $false
    }
    $manualTrigger = New-ScheduledTaskTrigger -Once -At $firstRun
    $manualTrigger.Id = $script:CfnManualTriggerId
    $manualTrigger.Repetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern `
        -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
            Interval = "PT${IntervalMinutes}M"
            Duration = ConvertTo-CfnIsoDuration $duration
            StopAtDurationEnd = $true
        }
    Set-ScheduledTask -TaskName $TaskName -Trigger @($baseTriggers + $manualTrigger) -ErrorAction Stop | Out-Null
    return $true
}

function Invoke-CfnGuiDrainNow {
    param([Parameter(Mandatory = $true)] [string] $InstallRoot)

    $drainPath = Join-Path $InstallRoot 'drain.ps1'
    if (-not (Test-Path -LiteralPath $drainPath -PathType Leaf)) { throw "投递脚本不存在：$drainPath" }
    $arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "{0}"' -f $drainPath.Replace('"', '\"')
    Start-Process -FilePath (Get-CfnGuiPowerShellExecutable) -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Clear-CfnGuiManualDeliveryOverride {
    param(
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [string] $TaskName
    )

    if (Get-CfnGuiTask $TaskName) {
        Set-CfnGuiManualTrigger -TaskName $TaskName -Enabled $false | Out-Null
    }
    Clear-CfnManualDeliveryState $InstallRoot
    Write-CfnLog $InstallRoot 'manual_control' 'cleared' '' 'schedule-master-toggle'
}

function Invoke-CfnGuiManualDeliveryToggle {
    param(
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [string] $TaskName,
        [datetime] $Now = (Get-Date),
        [switch] $NoImmediateDrain
    )

    $task = Get-CfnGuiTask $TaskName
    if (-not $task) { throw "计划任务不存在：$TaskName" }
    if ([string]$task.State -eq 'Disabled') { throw '运行计划已关闭；请先打开“运行计划：已关闭”。' }
    $settings = Get-CfnSettings $InstallRoot
    $control = Get-CfnDeliveryControlState $InstallRoot $settings $Now
    $nextStart = [datetime]$control.NextScheduleStart

    if ($control.EffectiveActive) {
        # Persist the pause before stopping/removing triggers so a racing drain
        # also observes the stop request.
        $manual = Set-CfnManualDeliveryState $InstallRoot 'pause' ([datetimeoffset]$nextStart) ([datetimeoffset]$Now)
        if ([string]$task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
        Set-CfnGuiManualTrigger -TaskName $TaskName -Enabled $false | Out-Null
        Write-CfnLog $InstallRoot 'manual_control' 'paused' '' "until=$($manual.ExpiresAt.ToString('o'))"
        return [pscustomobject]@{
            Action = 'paused'
            EffectiveActive = $false
            ExpiresAt = $manual.ExpiresAt
            TemporaryTrigger = $false
        }
    }

    Set-CfnGuiManualTrigger -TaskName $TaskName -Enabled $false | Out-Null
    if ($control.ScheduledActive) {
        Clear-CfnManualDeliveryState $InstallRoot
        $expiresAt = $null
        $temporaryTrigger = $false
        $action = 'resumed'
    } else {
        $manual = Set-CfnManualDeliveryState $InstallRoot 'force' ([datetimeoffset]$nextStart) ([datetimeoffset]$Now)
        try {
            $temporaryTrigger = Set-CfnGuiManualTrigger -TaskName $TaskName -Enabled $true `
                -ExpiresAt $nextStart -IntervalMinutes $settings.IntervalMinutes -Now $Now
        } catch {
            Clear-CfnManualDeliveryState $InstallRoot
            throw
        }
        $expiresAt = $manual.ExpiresAt
        $action = 'forced'
    }
    if (-not $NoImmediateDrain) { Invoke-CfnGuiDrainNow $InstallRoot }
    Write-CfnLog $InstallRoot 'manual_control' $action '' $(if ($null -ne $expiresAt) { "until=$($expiresAt.ToString('o'))" } else { 'current-window' })
    return [pscustomobject]@{
        Action = $action
        EffectiveActive = $true
        ExpiresAt = $expiresAt
        TemporaryTrigger = [bool]$temporaryTrigger
    }
}

function Get-CfnGuiStatus {
    param(
        [Parameter(Mandatory = $true)] [string] $InstallRoot,
        [Parameter(Mandatory = $true)] [string] $TaskName
    )

    $task = Get-CfnGuiTask $TaskName
    $info = $null
    if ($task -and (Get-Command Get-ScheduledTaskInfo -ErrorAction SilentlyContinue)) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    $dailyCount = if ($task) {
        @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' }).Count
    } else { 0 }
    $holidayCount = if ($task) {
        @($task.Triggers | Where-Object {
            $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' -and [string]$_.Id -ne $script:CfnManualTriggerId
        }).Count
    } else { 0 }
    $manualTriggerPresent = [bool]($task -and @($task.Triggers | Where-Object { [string]$_.Id -eq $script:CfnManualTriggerId }).Count -gt 0)
    $weeklyCount = if ($task) {
        @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger' }).Count
    } else { 0 }
    $pendingCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\pending') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $suppressedCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\suppressed') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $waitingCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\state\waiting') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $completionArmCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\state\completion') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $readySessionCount = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'spool\state\ready') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $settingsPath = Join-Path $InstallRoot 'settings.local.json'
    $feishuEnabled = $true
    $runtimeSettings = $null
    $deliveryControl = $null
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $runtimeSettings = Get-CfnSettings $InstallRoot
            $feishuEnabled = [bool]$runtimeSettings.FeishuEnabled
            $deliveryControl = Get-CfnDeliveryControlState $InstallRoot $runtimeSettings
        } catch {}
    }
    $hooksPath = Join-Path $env:USERPROFILE '.codex\hooks.json'
    $lifecycleHookCount = 0
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        try {
            $hookText = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8
            $hookDocument = $hookText | ConvertFrom-Json
            $hookContainer = if ($hookDocument.PSObject.Properties['hooks']) { $hookDocument.hooks } else { $hookDocument }
            $expectedHookPath = Join-Path $InstallRoot 'hook.ps1'
            foreach ($eventName in @('PermissionRequest', 'PostToolUse', 'UserPromptSubmit', 'SessionStart', 'Stop')) {
                $eventProperty = $hookContainer.PSObject.Properties[$eventName]
                if (-not $eventProperty) { continue }
                $eventMatches = $false
                foreach ($handlerGroup in @($eventProperty.Value)) {
                    $handlerCandidates = @($handlerGroup)
                    if ($handlerGroup.PSObject.Properties['hooks']) {
                        $handlerCandidates += @($handlerGroup.hooks)
                    }
                    foreach ($handler in $handlerCandidates) {
                        foreach ($propertyName in @('command', 'commandWindows')) {
                            $commandProperty = $handler.PSObject.Properties[$propertyName]
                            if ($commandProperty -and
                                [string]$commandProperty.Value -and
                                ([string]$commandProperty.Value).IndexOf($expectedHookPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                $eventMatches = $true
                                break
                            }
                        }
                        if ($eventMatches) { break }
                    }
                    if ($eventMatches) { break }
                }
                if ($eventMatches) { $lifecycleHookCount++ }
            }
        } catch {}
    }

    [pscustomobject]@{
        TaskExists = [bool]$task
        State = if ($task) { [string]$task.State } else { 'Missing' }
        ScheduleEnabled = [bool]($task -and [string]$task.State -ne 'Disabled')
        FeishuEnabled = $feishuEnabled
        ScheduledNow = [bool]($null -ne $deliveryControl -and $deliveryControl.ScheduledActive)
        DeliveryActive = [bool]($task -and [string]$task.State -ne 'Disabled' -and $null -ne $deliveryControl -and $deliveryControl.EffectiveActive)
        DeliveryReason = if ($null -ne $deliveryControl) { [string]$deliveryControl.Reason } else { 'unavailable' }
        ManualMode = if ($null -ne $deliveryControl) { [string]$deliveryControl.ManualMode } else { '' }
        ManualExpiresAt = if ($null -ne $deliveryControl) { $deliveryControl.ManualExpiresAt } else { $null }
        NextScheduleStart = if ($null -ne $deliveryControl) { $deliveryControl.NextScheduleStart } else { $null }
        ManualTriggerPresent = $manualTriggerPresent
        LastRunTime = if ($info) { $info.LastRunTime } else { $null }
        NextRunTime = if ($info) { $info.NextRunTime } else { $null }
        LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
        DailyTriggerCount = $dailyCount
        WeeklyTriggerCount = $weeklyCount
        HolidayTriggerCount = $holidayCount
        AllowDemandStart = if ($task) { [bool]$task.Settings.AllowDemandStart } else { $null }
        StartWhenAvailable = if ($task) { [bool]$task.Settings.StartWhenAvailable } else { $null }
        PendingCount = $pendingCount
        SuppressedCount = $suppressedCount
        WaitingCount = $waitingCount
        CompletionArmCount = $completionArmCount
        ReadySessionCount = $readySessionCount
        LifecycleHookCount = $lifecycleHookCount
        HooksPath = $hooksPath
        SettingsExists = (Test-Path -LiteralPath $settingsPath -PathType Leaf)
        InstallStateExists = (Test-Path -LiteralPath (Join-Path $InstallRoot 'install-state.json') -PathType Leaf)
        LogRoot = (Join-Path $InstallRoot 'logs')
        BackupRoot = (Join-Path $InstallRoot 'backups')
    }
}

Export-ModuleMember -Function @(
    'Get-CfnGuiTarget',
    'Get-CfnGuiLarkCliResolution',
    'Get-CfnGuiLarkProfiles',
    'Get-CfnGuiModel',
    'Test-CfnGuiModel',
    'Get-CfnGuiInstallParameters',
    'Set-CfnGuiFeishuEnabled',
    'Set-CfnGuiManualTrigger',
    'Clear-CfnGuiManualDeliveryOverride',
    'Invoke-CfnGuiManualDeliveryToggle',
    'Get-CfnGuiStatus'
)
