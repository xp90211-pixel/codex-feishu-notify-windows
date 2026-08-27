[CmdletBinding()]
param(
    [string] $InstallRoot = '',
    [string] $TaskName = '',
    [switch] $ValidateOnly,
    [switch] $SmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'The graphical settings tool supports Windows only.' }

if (-not $ValidateOnly -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $powerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $powerShell) {
        $powerShell = Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
        ('"{0}"' -f $PSCommandPath.Replace('"', '\"'))
    )
    if ($InstallRoot) { $arguments += @('-InstallRoot', ('"{0}"' -f $InstallRoot.Replace('"', '\"'))) }
    if ($TaskName) { $arguments += @('-TaskName', ('"{0}"' -f $TaskName.Replace('"', '\"'))) }
    if ($SmokeTest) { $arguments += '-SmokeTest' }
    Start-Process -FilePath $powerShell.Source -ArgumentList $arguments | Out-Null
    return
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiModulePath = Join-Path $projectRoot 'src\CodexFeishuNotify.Gui.psm1'
$installerPath = Join-Path $PSScriptRoot 'Install.ps1'
$uninstallerPath = Join-Path $PSScriptRoot 'Uninstall.ps1'
$testConfigurationPath = Join-Path $PSScriptRoot 'Test-Configuration.ps1'
foreach ($requiredPath in @($guiModulePath, $installerPath, $uninstallerPath, $testConfigurationPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Project file was not found: $requiredPath"
    }
}
Import-Module $guiModulePath -Force -DisableNameChecking

$target = Get-CfnGuiTarget -InstallRoot $InstallRoot -TaskName $TaskName
$model = Get-CfnGuiModel -InstallRoot $target.InstallRoot -TaskName $target.TaskName

if ($ValidateOnly) {
    $validation = Test-CfnGuiModel $model
    [pscustomobject]@{
        valid = $validation.Valid
        source = $model.Source
        source_path = $model.SourcePath
        task_name = $target.TaskName
        install_root = $target.InstallRoot
        task_exists = $target.TaskExists
        schedule_enabled = $model.ScheduleEnabled
        feishu_enabled = $model.FeishuEnabled
        chat_id_configured = ([string]$model.ChatId -match '^oc_')
        schedule_start = $model.ScheduleStart
        schedule_end = $model.ScheduleEnd
        interval_minutes = $model.IntervalMinutes
        holiday_region = $model.HolidayRegion
        all_day_weekdays = @($model.AllDayWeekdays)
        message_format = $model.MessageFormat
        strict_completion_gate = $model.StrictCompletionGate
        permission_notifications = $model.NotifyPermissionRequests
        desktop_enabled = $model.DesktopEnabled
        desktop_only_when_codex_background = $model.DesktopOnlyWhenCodexBackground
        lark_cli_mode = $(if ([string]::IsNullOrWhiteSpace([string]$model.LarkCliPath)) { 'auto' } else { 'explicit' })
        resolved_lark_cli_path = $model.ResolvedLarkCliPath
        errors = @($validation.Errors)
        warnings = @($validation.Warnings)
    } | ConvertTo-Json -Depth 4
    if (-not $validation.Valid) { exit 1 }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('CfnGuiNativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CfnGuiNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
}
'@
}

function Set-CfnCueBanner {
    param(
        [Parameter(Mandatory = $true)] [System.Windows.Forms.TextBox] $TextBox,
        [Parameter(Mandatory = $true)] [string] $Text
    )

    # EM_SETCUEBANNER is available on supported Windows versions and preserves
    # an actually empty value, so the installer still receives auto-detect mode.
    [void]$TextBox.Handle
    [void][CfnGuiNativeMethods]::SendMessage($TextBox.Handle, 0x1501, [IntPtr]1, $Text)
}

function New-CfnLabel {
    param([string] $Text, [int] $X, [int] $Y, [int] $Width = 130, [int] $Height = 24)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function New-CfnTextBox {
    param([int] $X, [int] $Y, [int] $Width, [int] $Height = 25)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, $Height)
    return $box
}

function Get-CfnSelectedModel {
    [pscustomobject]@{
        InstallRoot = $script:target.InstallRoot
        TaskName = $script:target.TaskName
        Source = $script:model.Source
        ChatId = $script:chatIdText.Text.Trim()
        LarkCliPath = $script:larkCliText.Text.Trim()
        LarkChannelHome = $script:channelHomeText.Text.Trim()
        LarkChannelProfile = ([string]$script:profileCombo.SelectedItem).Trim()
        RequireLarkProfile = $script:requireProfileCheck.Checked
        FeishuEnabled = $script:feishuToggleButton.Checked
        ScheduleEnabled = $script:taskToggleButton.Checked
        SendAttemptsPerRun = [int]$script:sendAttemptsNumber.Value
        RetryDelaySeconds = [int]$script:retryDelayNumber.Value
        VisibleThreadsOnly = $script:visibleOnlyCheck.Checked
        SkipBridgeOrigin = $script:skipBridgeCheck.Checked
        StrictCompletionGate = $script:strictGateCheck.Checked
        NotifyPermissionRequests = $script:permissionNotifyCheck.Checked
        DesktopEnabled = $script:desktopEnabledCheck.Checked
        DesktopOnlyWhenCodexBackground = $script:desktopBackgroundCheck.Checked
        DesktopCompletion = $script:desktopCompletionCheck.Checked
        DesktopPermissionRequest = $script:desktopPermissionCheck.Checked
        ScheduleStart = $script:startPicker.Value.ToString('HH:mm')
        ScheduleEnd = $script:endPicker.Value.ToString('HH:mm')
        IntervalMinutes = [int]$script:intervalNumber.Value
        HolidayRegion = [string]$script:holidayRegionCombo.SelectedItem
        HolidayCalendarPath = $script:calendarText.Text.Trim()
        AllDayWeekdays = @($script:weekdayChecks.Keys | Where-Object { $script:weekdayChecks[$_].Checked })
        MaxQueueAgeHours = [int]$script:maxQueueNumber.Value
        IncludeTaskPreview = $script:taskPreviewCheck.Checked
        IncludeResultPreview = $script:resultPreviewCheck.Checked
        IncludePermissionTool = $script:permissionToolCheck.Checked
        MessageFormat = [string]$script:messageFormatCombo.SelectedItem
    }
}

function Set-CfnPickerTime {
    param([System.Windows.Forms.DateTimePicker] $Picker, [string] $Value)
    $parsed = [datetime]::Today
    if ([datetime]::TryParseExact(
        $Value,
        'HH:mm',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )) {
        $Picker.Value = $parsed
    }
}

function Update-CfnLarkCliResolution {
    $configured = $script:larkCliText.Text.Trim()
    $resolution = Get-CfnGuiLarkCliResolution $configured
    if ($resolution.Mode -eq 'explicit') {
        if ($resolution.Found) {
            $script:larkCliResolutionLabel.Text = "使用指定路径：$($resolution.Path)"
            $script:larkCliResolutionLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $script:larkCliResolutionLabel.Text = "指定路径不存在：$($resolution.Path)"
            $script:larkCliResolutionLabel.ForeColor = [System.Drawing.Color]::Firebrick
        }
        return
    }

    if ($resolution.Found) {
        $script:larkCliResolutionLabel.Text = "已自动找到：$($resolution.Path)"
        $script:larkCliResolutionLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $script:larkCliResolutionLabel.Text = '未自动找到 lark-cli；请点击“浏览…”指定路径'
        $script:larkCliResolutionLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}

function Set-CfnScheduleToggleState {
    param([bool] $Enabled)

    $script:taskToggleButton.Checked = $Enabled
    $script:taskToggleButton.Text = if ($Enabled) { '运行计划：已开启' } else { '运行计划：已关闭' }
    $script:taskToggleButton.ForeColor = if ($Enabled) {
        [System.Drawing.Color]::DarkGreen
    } else {
        [System.Drawing.Color]::Firebrick
    }
}

function Set-CfnInstantDeliveryState {
    param($Status)

    $available = [bool]($Status.TaskExists -and $Status.ScheduleEnabled -and $Status.SettingsExists)
    $script:instantDeliveryButton.Enabled = $available
    if (-not $available) {
        $script:instantDeliveryButton.Text = '马上开始'
        $script:instantDeliveryButton.ForeColor = [System.Drawing.SystemColors]::GrayText
        $script:instantDeliveryHint.Text = if (-not $Status.ScheduleEnabled) {
            '运行计划已关闭；打开总开关后才可使用即时控制。'
        } else {
            '请先安装通知并生成受管配置。'
        }
        return
    }

    if ($Status.DeliveryActive) {
        $script:instantDeliveryButton.Text = '立刻停止'
        $script:instantDeliveryButton.ForeColor = [System.Drawing.Color]::Firebrick
    } else {
        $script:instantDeliveryButton.Text = '马上开始'
        $script:instantDeliveryButton.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    $expiry = Format-CfnDateTime $Status.ManualExpiresAt
    $nextStart = Format-CfnDateTime $Status.NextScheduleStart
    $script:instantDeliveryHint.Text = switch ([string]$Status.ManualMode) {
        'force' { "临时运行中；$expiry 起自动交回正常运行时段。" }
        'pause' { "已临时停止；$expiry 到达下个运行时段时自动恢复，也可再次点击马上开始。" }
        default {
            if ($Status.ScheduledNow) {
                "当前处于正常运行时段；点击可停止至下个运行时段（$nextStart）。"
            } else {
                "当前不在运行时段；点击后立即运行至 $nextStart，再交回正常规则。"
            }
        }
    }
}

function Set-CfnFeishuToggleState {
    param([bool] $Enabled)

    $script:feishuToggleButton.Checked = $Enabled
    $script:feishuToggleButton.Text = if ($Enabled) { '飞书通知：已开启' } else { '飞书通知：已关闭' }
    $script:feishuToggleButton.ForeColor = if ($Enabled) {
        [System.Drawing.Color]::DarkGreen
    } else {
        [System.Drawing.Color]::Firebrick
    }
}

function Update-CfnProfileControls {
    $script:profileCombo.Enabled = [bool]$script:requireProfileCheck.Checked
}

function Update-CfnDesktopControls {
    $enabled = [bool]$script:desktopEnabledCheck.Checked
    foreach ($control in @(
        $script:desktopBackgroundCheck,
        $script:desktopCompletionCheck,
        $script:desktopPermissionCheck
    )) {
        $control.Enabled = $enabled
    }
}

function Update-CfnProfileChoices {
    param([AllowEmptyString()] [string] $PreferredProfile = '')

    $currentProfile = if ($PreferredProfile) {
        $PreferredProfile
    } else {
        [string]$script:profileCombo.SelectedItem
    }
    $profiles = @(Get-CfnGuiLarkProfiles $script:channelHomeText.Text.Trim())

    $script:profileCombo.BeginUpdate()
    try {
        $script:profileCombo.Items.Clear()
        foreach ($profile in $profiles) { [void]$script:profileCombo.Items.Add($profile) }
        if ($currentProfile -and $script:profileCombo.Items.Contains($currentProfile)) {
            $script:profileCombo.SelectedItem = $currentProfile
        } elseif (-not $currentProfile -and $script:profileCombo.Items.Count -gt 0) {
            $script:profileCombo.SelectedIndex = 0
        } else {
            $script:profileCombo.SelectedIndex = -1
        }
    } finally {
        $script:profileCombo.EndUpdate()
    }
    Update-CfnProfileControls
}

function Set-CfnControlsFromModel {
    param($Value)

    $script:taskNameText.Text = [string]$Value.TaskName
    $script:installRootText.Text = [string]$Value.InstallRoot
    $script:chatIdText.Text = [string]$Value.ChatId
    $script:larkCliText.Text = [string]$Value.LarkCliPath
    $script:channelHomeText.Text = [string]$Value.LarkChannelHome
    Update-CfnProfileChoices ([string]$Value.LarkChannelProfile)
    $script:requireProfileCheck.Checked = [bool]$Value.RequireLarkProfile
    Update-CfnProfileControls
    Set-CfnFeishuToggleState ([bool]$Value.FeishuEnabled)
    Set-CfnScheduleToggleState ([bool]$Value.ScheduleEnabled)
    $script:sendAttemptsNumber.Value = [decimal]([math]::Max(1, [math]::Min(5, [int]$Value.SendAttemptsPerRun)))
    $script:retryDelayNumber.Value = [decimal]([math]::Max(0, [math]::Min(30, [int]$Value.RetryDelaySeconds)))
    $script:visibleOnlyCheck.Checked = [bool]$Value.VisibleThreadsOnly
    $script:skipBridgeCheck.Checked = [bool]$Value.SkipBridgeOrigin
    $script:strictGateCheck.Checked = [bool]$Value.StrictCompletionGate
    $script:permissionNotifyCheck.Checked = [bool]$Value.NotifyPermissionRequests
    $script:desktopEnabledCheck.Checked = [bool]$Value.DesktopEnabled
    $script:desktopBackgroundCheck.Checked = [bool]$Value.DesktopOnlyWhenCodexBackground
    $script:desktopCompletionCheck.Checked = [bool]$Value.DesktopCompletion
    $script:desktopPermissionCheck.Checked = [bool]$Value.DesktopPermissionRequest
    Update-CfnDesktopControls
    $script:taskPreviewCheck.Checked = [bool]$Value.IncludeTaskPreview
    $script:resultPreviewCheck.Checked = [bool]$Value.IncludeResultPreview
    $script:permissionToolCheck.Checked = [bool]$Value.IncludePermissionTool
    $script:messageFormatCombo.SelectedItem = [string]$Value.MessageFormat
    if ($null -eq $script:messageFormatCombo.SelectedItem) { $script:messageFormatCombo.SelectedItem = 'card' }
    Set-CfnPickerTime $script:startPicker ([string]$Value.ScheduleStart)
    Set-CfnPickerTime $script:endPicker ([string]$Value.ScheduleEnd)
    $script:intervalNumber.Value = [decimal]([math]::Max(1, [math]::Min(60, [int]$Value.IntervalMinutes)))
    $script:maxQueueNumber.Value = [decimal]([math]::Max(1, [math]::Min(720, [int]$Value.MaxQueueAgeHours)))

    $region = [string]$Value.HolidayRegion
    if ($region -notin @('Auto', 'SG', 'CN', 'None', 'Custom')) { $region = 'Custom' }
    $script:holidayRegionCombo.SelectedItem = $region
    $script:calendarText.Text = [string]$Value.HolidayCalendarPath
    $weekdayProperty = $Value.PSObject.Properties['AllDayWeekdays']
    $selectedWeekdays = if ($null -ne $weekdayProperty) { @($weekdayProperty.Value) } else { @() }
    foreach ($weekday in $script:weekdayChecks.Keys) {
        $script:weekdayChecks[$weekday].Checked = ($selectedWeekdays -contains $weekday)
    }
    Update-CfnCalendarControls

    $sourcePathProperty = $Value.PSObject.Properties['SourcePath']
    $sourcePath = if ($null -ne $sourcePathProperty -and [string]$sourcePathProperty.Value) {
        [string]$sourcePathProperty.Value
    } else {
        Join-Path ([string]$Value.InstallRoot) 'settings.local.json'
    }
    switch ([string]$Value.Source) {
        'managed' {
            $script:sourceLabel.Text = "当前读取来源：受管配置`r`n$sourcePath"
            $script:sourceLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        'legacy' {
            $script:sourceLabel.Text = "当前读取来源：旧版脚本（首次应用会迁移并备份）`r`n$sourcePath"
            $script:sourceLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        default {
            $script:sourceLabel.Text = "当前读取来源：默认值（尚未找到本地配置）`r`n预期配置路径：$sourcePath"
            $script:sourceLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    }
    Update-CfnLarkCliResolution
}

function Update-CfnCalendarControls {
    $mode = [string]$script:holidayRegionCombo.SelectedItem
    $custom = ($mode -eq 'Custom')
    $script:calendarText.Enabled = $custom
    $script:calendarBrowseButton.Enabled = $custom
    $script:holidayModeExplanation.Text = switch ($mode) {
        'Auto' { '应用设置时按 Windows“国家或地区”自动选择 SG、CN 或关闭；解析后使用对应的本地日历，所列日期补齐为全天运行。' }
        'SG' { '使用内置的新加坡 2026–2027 公共假日日历；日历列出的假日和顺延日补齐为全天运行，普通周末不会自动全天。' }
        'CN' { '使用内置的中国 2026 官方放假日历；官方放假日期补齐为全天运行，调休上班日不会作为全天运行日。' }
        'None' { '不使用节假日日历；日期只遵循每日时间窗以及下方勾选的“全天运行日”。' }
        'Custom' { '使用所选 JSON 的 holidays 日期；文件中列出的日期补齐为全天运行，应用设置后才会重新生成计划任务。' }
        default { '请选择节假日模式。' }
    }
}

function Format-CfnDateTime {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [datetimeoffset]) { return $Value.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }
    if ([datetime]$Value -eq [datetime]::MinValue) { return '-' }
    return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss')
}

function Update-CfnStatus {
    try {
        $status = Get-CfnGuiStatus -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        $script:taskToggleButton.Enabled = $status.TaskExists
        $script:feishuToggleButton.Enabled = $status.SettingsExists
        $script:uninstallButton.Enabled = $status.InstallStateExists
        Set-CfnScheduleToggleState ([bool]$status.ScheduleEnabled)
        Set-CfnFeishuToggleState ([bool]$status.FeishuEnabled)
        Set-CfnInstantDeliveryState $status
        $script:model.ScheduleEnabled = [bool]$status.ScheduleEnabled
        $script:model.FeishuEnabled = [bool]$status.FeishuEnabled
        $lines = @(
            "运行计划：$(if ($status.ScheduleEnabled) { '已启用' } else { '已停用' })    飞书通知：$(if ($status.FeishuEnabled) { '已打开' } else { '已关闭' })    任务状态：$($status.State)",
            "即时投递：$(if ($status.DeliveryActive) { '运行中' } else { '已停止' })（$($status.DeliveryReason)）    临时触发器：$($status.ManualTriggerPresent)    临时状态截止：$(Format-CfnDateTime $status.ManualExpiresAt)",
            "每日触发器：$($status.DailyTriggerCount)    每周全天触发器：$($status.WeeklyTriggerCount)    节假日触发器：$($status.HolidayTriggerCount)    待发送：$($status.PendingCount)    已抑制：$($status.SuppressedCount)",
            "上次运行：$(Format-CfnDateTime $status.LastRunTime)    下次运行：$(Format-CfnDateTime $status.NextRunTime)    返回码：$($status.LastTaskResult)",
            "生命周期 Hook：$($status.LifecycleHookCount)/5    已就绪会话：$($status.ReadySessionCount)    等待状态：$($status.WaitingCount)    完成门：$($status.CompletionArmCount)",
            "安全约束：按需启动=$($status.AllowDemandStart)；错过后补跑=$($status.StartWhenAvailable)；私有配置=$($status.SettingsExists)"
        )
        $script:statusText.Text = $lines -join [Environment]::NewLine
    } catch {
        $script:statusText.Text = "读取任务状态失败：$($_.Exception.Message)"
        $script:taskToggleButton.Enabled = $false
        $script:taskToggleButton.Checked = $false
        $script:taskToggleButton.Text = '运行计划：不可用'
        $script:taskToggleButton.ForeColor = [System.Drawing.SystemColors]::GrayText
        $script:feishuToggleButton.Enabled = $false
        $script:feishuToggleButton.Checked = $false
        $script:feishuToggleButton.Text = '飞书通知：不可用'
        $script:feishuToggleButton.ForeColor = [System.Drawing.SystemColors]::GrayText
        $script:instantDeliveryButton.Enabled = $false
        $script:instantDeliveryButton.Text = '马上开始'
        $script:instantDeliveryButton.ForeColor = [System.Drawing.SystemColors]::GrayText
        $script:instantDeliveryHint.Text = '即时控制状态不可用。'
    }
}

function Show-CfnValidation {
    param($Validation, [switch] $Quiet)

    $parts = New-Object System.Collections.Generic.List[string]
    if ($Validation.Valid) {
        $parts.Add('配置检查通过。')
        if ($Validation.Window) {
            $parts.Add(('每日运行时长：{0} 分钟（{1}）' -f [int]$Validation.Window.Duration.TotalMinutes, $Validation.Window.IsoDuration))
        }
    } else {
        $parts.Add('配置存在错误：')
        foreach ($item in @($Validation.Errors)) { $parts.Add("• $item") }
    }
    if (@($Validation.Warnings).Count -gt 0) {
        $parts.Add('')
        $parts.Add('提醒：')
        foreach ($item in @($Validation.Warnings)) { $parts.Add("• $item") }
    }
    $message = $parts -join [Environment]::NewLine
    $script:statusText.Text = $message
    if ($script:settingsTabs -and $script:statusTab) {
        $script:settingsTabs.SelectedTab = $script:statusTab
    }
    if (-not $Quiet) {
        $icon = if ($Validation.Valid) {
            [System.Windows.Forms.MessageBoxIcon]::Information
        } else {
            [System.Windows.Forms.MessageBoxIcon]::Error
        }
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $message, '配置检查', 'OK', $icon)
    }
}

function Set-CfnBusy {
    param([bool] $Busy)
    $script:form.UseWaitCursor = $Busy
    foreach ($button in @($script:applyButton, $script:validateButton, $script:reloadButton, $script:taskToggleButton, $script:instantDeliveryButton, $script:feishuToggleButton, $script:installButton, $script:uninstallButton)) {
        $button.Enabled = -not $Busy
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-CfnPowerShellExecutable {
    $current = try { (Get-Process -Id $PID -ErrorAction Stop).Path } catch { '' }
    if ($current -and (Test-Path -LiteralPath $current -PathType Leaf)) { return $current }
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { return $pwsh.Source }
    return (Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
}

function Invoke-CfnGuiDeployment {
    param(
        [ValidateSet('Apply', 'Install')]
        [string] $Mode = 'Apply'
    )

    $selected = $null
    $deploymentOutcome = ''
    $isInstall = ($Mode -eq 'Install')
    try {
        $selected = Get-CfnSelectedModel
        $validation = Test-CfnGuiModel $selected
        if (-not $validation.Valid) {
            Show-CfnValidation $validation
            return
        }
        $warningText = if (@($validation.Warnings).Count) {
            [Environment]::NewLine + [Environment]::NewLine + '提醒：' + [Environment]::NewLine + (@($validation.Warnings) -join [Environment]::NewLine)
        } else { '' }
        $weekdayDisplay = if (@($selected.AllDayWeekdays).Count -gt 0) {
            $displayNames = @{ Monday = '周一'; Tuesday = '周二'; Wednesday = '周三'; Thursday = '周四'; Friday = '周五'; Saturday = '周六'; Sunday = '周日' }
            @($selected.AllDayWeekdays | ForEach-Object { $displayNames[[string]$_] }) -join '、'
        } else { '未选择' }
        $operationSummary = if ($isInstall) {
            '将按当前界面配置首次安装或修复通知。已有本机配置、其他 Codex Hook 和原通知命令会先备份并尽量保留。'
        } else {
            '将按当前界面配置重新应用设置。'
        }
        $confirmation = @(
            $operationSummary,
            '',
            "计划任务：$($selected.TaskName)",
            "安装目录：$($selected.InstallRoot)",
            "运行计划：$(if ($selected.ScheduleEnabled) { '启用' } else { '停用' })",
            "飞书通知：$(if ($selected.FeishuEnabled) { '打开' } else { '关闭' })",
            "每日时间窗：$($selected.ScheduleStart)–$($selected.ScheduleEnd)",
            "检查间隔：$($selected.IntervalMinutes) 分钟",
            "节假日模式：$($selected.HolidayRegion)",
            "全天运行日：$weekdayDisplay",
            "飞书格式：$($selected.MessageFormat)",
            "严格完成门：$($selected.StrictCompletionGate)",
            "等待授权通知：$($selected.NotifyPermissionRequests)",
            "PC 通知：$($selected.DesktopEnabled)（仅后台：$($selected.DesktopOnlyWhenCodexBackground)）",
            '',
            '安装器会部署通知脚本、合并用户级生命周期 Hook、修复 Codex notify 命令链并重新注册计划任务，但不会手动启动任务。',
            '完成后仍需重新打开 Codex，并在 Hook 管理界面审查、信任和启用新安装或发生变化的 Hook；设置器不会绕过此安全步骤。',
            '',
            '是否继续？'
        ) -join [Environment]::NewLine
        $confirmTitle = if ($isInstall) { '确认安装通知' } else { '确认应用设置' }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:form,
            $confirmation + $warningText,
            $confirmTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Set-CfnBusy $true
        $script:settingsTabs.SelectedTab = $script:statusTab
        $script:statusText.Text = if ($isInstall) {
            '正在备份、安装或修复通知并验证，请稍候…'
        } else {
            '正在备份、应用并验证设置，请稍候…'
        }
        [System.Windows.Forms.Application]::DoEvents()
        $parameters = Get-CfnGuiInstallParameters $selected
        $installOutput = (& $script:installerPath @parameters -Confirm:$false 2>&1 | Out-String).Trim()

        $powerShell = Get-CfnPowerShellExecutable
        $verifyOutput = (& $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:testConfigurationPath `
            -InstallRoot $selected.InstallRoot -TaskName $selected.TaskName 2>&1 | Out-String).Trim()
        $verifyExitCode = $LASTEXITCODE
        if ($verifyExitCode -ne 0) {
            throw "设置已写入，但验证未通过。请查看备份和检查结果。`r`n`r`n$verifyOutput"
        }

        $script:target = Get-CfnGuiTarget -InstallRoot $selected.InstallRoot -TaskName $selected.TaskName
        $script:model = Get-CfnGuiModel -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        Set-CfnControlsFromModel $script:model
        Update-CfnStatus
        $successLead = if ($isInstall) { '通知已安装或修复，配置检查通过。' } else { '设置已应用并验证通过。' }
        $deploymentOutcome = @($successLead, '', $installOutput, '', $verifyOutput) -join [Environment]::NewLine
        $successMessage = @(
            $successLead,
            '计划任务没有被手动启动。',
            '',
            '请完全退出并重新打开 Codex，然后审查、信任并启用这套通知的 5 个生命周期 Hook。'
        ) -join [Environment]::NewLine
        [void][System.Windows.Forms.MessageBox]::Show(
            $script:form,
            $successMessage,
            $(if ($isInstall) { '安装通知完成' } else { '完成' }),
            'OK',
            'Information'
        )
    } catch {
        $deploymentOutcome = $_.Exception.Message
        $failureTitle = if ($isInstall) { '安装通知失败' } else { '应用失败' }
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, $failureTitle, 'OK', 'Error')
    } finally {
        Set-CfnBusy $false
        Update-CfnStatus
        if ($deploymentOutcome) {
            $script:statusText.Text = $deploymentOutcome + [Environment]::NewLine + [Environment]::NewLine + $script:statusText.Text
        }
    }
}

function New-CfnLayoutLabel {
    param(
        [string] $Text,
        [switch] $Bold,
        [int] $TopMargin = 6
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $label.Margin = New-Object System.Windows.Forms.Padding(3, $TopMargin, 8, 3)
    if ($Bold) {
        $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    }
    return $label
}

function New-CfnSectionGroup {
    param([string] $Text)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Text
    $group.Dock = [System.Windows.Forms.DockStyle]::Top
    $group.AutoSize = $true
    $group.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    return $group
}

function New-CfnCheckFlow {
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = [System.Windows.Forms.DockStyle]::Top
    $flow.AutoSize = $true
    $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flow.WrapContents = $true
    $flow.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
    return $flow
}

function Set-CfnButtonLayout {
    param(
        [System.Windows.Forms.Button] $Button,
        [int] $Width = 100
    )
    $Button.Size = New-Object System.Drawing.Size($Width, 34)
    $Button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex 飞书通知设置'
$form.ClientSize = New-Object System.Drawing.Size(960, 760)
$form.MinimumSize = New-Object System.Drawing.Size(680, 520)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.SystemColors]::Control

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 4
$rootLayout.Padding = New-Object System.Windows.Forms.Padding(18, 12, 18, 10)
[void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 124)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$form.Controls.Add($rootLayout)

$headerLayout = New-Object System.Windows.Forms.TableLayoutPanel
$headerLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$headerLayout.AutoSize = $true
$headerLayout.ColumnCount = 1
$headerLayout.RowCount = 2
$headerLayout.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$headerLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$headerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$headerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$rootLayout.Controls.Add($headerLayout, 0, 0)

$title = New-CfnLayoutLabel 'Codex 飞书通知设置' -Bold -TopMargin 0
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$headerLayout.Controls.Add($title, 0, 0)
$subtitle = New-CfnLayoutLabel '修改后由安装器重新生成计划任务；不会手动启动任务，也不会改变常驻飞书 CLI。' -TopMargin 2
$subtitle.ForeColor = [System.Drawing.SystemColors]::GrayText
$headerLayout.Controls.Add($subtitle, 0, 1)

$targetGroup = New-Object System.Windows.Forms.GroupBox
$targetGroup.Text = '目标'
$targetGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$targetGroup.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$rootLayout.Controls.Add($targetGroup, 0, 1)

$targetLayout = New-Object System.Windows.Forms.TableLayoutPanel
$targetLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$targetLayout.ColumnCount = 4
$targetLayout.RowCount = 2
$targetLayout.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 4)
[void]$targetLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))
[void]$targetLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 42)))
[void]$targetLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 80)))
[void]$targetLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 58)))
[void]$targetLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$targetLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$targetGroup.Controls.Add($targetLayout)

$targetLayout.Controls.Add((New-CfnLayoutLabel '计划任务'), 0, 0)
$taskNameText = New-CfnTextBox 0 0 100
$taskNameText.ReadOnly = $true
$taskNameText.BackColor = [System.Drawing.SystemColors]::Window
$taskNameText.Dock = [System.Windows.Forms.DockStyle]::Fill
$targetLayout.Controls.Add($taskNameText, 1, 0)
$targetLayout.Controls.Add((New-CfnLayoutLabel '安装目录'), 2, 0)
$installRootText = New-CfnTextBox 0 0 100
$installRootText.ReadOnly = $true
$installRootText.BackColor = [System.Drawing.SystemColors]::Window
$installRootText.Dock = [System.Windows.Forms.DockStyle]::Fill
$targetLayout.Controls.Add($installRootText, 3, 0)
$sourceLabel = New-CfnLayoutLabel '' -TopMargin 5
$sourceLabel.AutoSize = $false
$sourceLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$sourceLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$targetLayout.Controls.Add($sourceLabel, 0, 1)
$targetLayout.SetColumnSpan($sourceLabel, 4)

$settingsTabs = New-Object System.Windows.Forms.TabControl
$settingsTabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$settingsTabs.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$rootLayout.Controls.Add($settingsTabs, 0, 2)

$basicTab = New-Object System.Windows.Forms.TabPage
$basicTab.Text = '飞书连接'
$basicTab.Padding = New-Object System.Windows.Forms.Padding(10)
$basicTab.AutoScroll = $true
$settingsTabs.TabPages.Add($basicTab)

$basicStack = New-Object System.Windows.Forms.TableLayoutPanel
$basicStack.Dock = [System.Windows.Forms.DockStyle]::Top
$basicStack.AutoSize = $true
$basicStack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$basicStack.ColumnCount = 1
$basicStack.RowCount = 3
[void]$basicStack.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
1..3 | ForEach-Object { [void]$basicStack.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
$basicTab.Controls.Add($basicStack)

$connectionGroup = New-CfnSectionGroup '飞书连接'
$basicStack.Controls.Add($connectionGroup, 0, 0)
$connectionLayout = New-Object System.Windows.Forms.TableLayoutPanel
$connectionLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$connectionLayout.AutoSize = $true
$connectionLayout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$connectionLayout.ColumnCount = 3
$connectionLayout.RowCount = 5
$connectionLayout.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 8)
[void]$connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 82)))
1..4 | ForEach-Object { [void]$connectionLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) }
[void]$connectionLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
$connectionGroup.Controls.Add($connectionLayout)

$connectionLayout.Controls.Add((New-CfnLayoutLabel '飞书会话 ID'), 0, 0)
$chatIdText = New-CfnTextBox 0 0 100
$chatIdText.UseSystemPasswordChar = $true
$chatIdText.Dock = [System.Windows.Forms.DockStyle]::Fill
$connectionLayout.Controls.Add($chatIdText, 1, 0)
$showChatCheck = New-Object System.Windows.Forms.CheckBox
$showChatCheck.Text = '显示'
$showChatCheck.AutoSize = $true
$showChatCheck.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$connectionLayout.Controls.Add($showChatCheck, 2, 0)

$connectionLayout.Controls.Add((New-CfnLayoutLabel 'Lark profile'), 0, 1)
$profilePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$profilePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$profilePanel.WrapContents = $false
$profilePanel.Margin = New-Object System.Windows.Forms.Padding(0)
$profileCombo = New-Object System.Windows.Forms.ComboBox
$profileCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$profileCombo.Size = New-Object System.Drawing.Size(190, 25)
$profileCombo.Margin = New-Object System.Windows.Forms.Padding(3, 3, 14, 3)
$profilePanel.Controls.Add($profileCombo)
$requireProfileCheck = New-Object System.Windows.Forms.CheckBox
$requireProfileCheck.Text = '使用独立 Lark profile（推荐）'
$requireProfileCheck.AutoSize = $true
$requireProfileCheck.Margin = New-Object System.Windows.Forms.Padding(0, 5, 3, 3)
$profilePanel.Controls.Add($requireProfileCheck)
$connectionLayout.Controls.Add($profilePanel, 1, 1)
$connectionLayout.SetColumnSpan($profilePanel, 2)

$connectionLayout.Controls.Add((New-CfnLayoutLabel '配置根目录'), 0, 2)
$channelHomeText = New-CfnTextBox 0 0 100
$channelHomeText.Dock = [System.Windows.Forms.DockStyle]::Fill
$connectionLayout.Controls.Add($channelHomeText, 1, 2)
$connectionLayout.SetColumnSpan($channelHomeText, 2)

$connectionLayout.Controls.Add((New-CfnLayoutLabel 'lark-cli 路径'), 0, 3)
$larkCliText = New-CfnTextBox 0 0 100
$larkCliText.Dock = [System.Windows.Forms.DockStyle]::Fill
$connectionLayout.Controls.Add($larkCliText, 1, 3)
Set-CfnCueBanner $larkCliText '留空＝自动查找'
$larkCliBrowseButton = New-Object System.Windows.Forms.Button
$larkCliBrowseButton.Text = '浏览…'
$larkCliBrowseButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$larkCliBrowseButton.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 5)
$connectionLayout.Controls.Add($larkCliBrowseButton, 2, 3)
$connectionLayout.Controls.Add((New-CfnLayoutLabel '路径状态' -TopMargin 4), 0, 4)
$larkCliResolutionLabel = New-CfnLayoutLabel '' -TopMargin 4
$larkCliResolutionLabel.AutoEllipsis = $true
$larkCliResolutionLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$connectionLayout.Controls.Add($larkCliResolutionLabel, 1, 4)
$connectionLayout.SetColumnSpan($larkCliResolutionLabel, 2)

$scheduleTab = New-Object System.Windows.Forms.TabPage
$scheduleTab.Text = '运行计划'
$scheduleTab.Padding = New-Object System.Windows.Forms.Padding(10)
$scheduleTab.AutoScroll = $true
$settingsTabs.TabPages.Add($scheduleTab)

$scheduleStack = New-Object System.Windows.Forms.TableLayoutPanel
$scheduleStack.Dock = [System.Windows.Forms.DockStyle]::Top
$scheduleStack.AutoSize = $true
$scheduleStack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$scheduleStack.ColumnCount = 1
$scheduleStack.RowCount = 1
[void]$scheduleStack.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$scheduleStack.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$scheduleTab.Controls.Add($scheduleStack)

$scheduleGroup = New-CfnSectionGroup '运行计划'
$scheduleStack.Controls.Add($scheduleGroup, 0, 0)
$scheduleLayout = New-Object System.Windows.Forms.TableLayoutPanel
$scheduleLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$scheduleLayout.AutoSize = $true
$scheduleLayout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$scheduleLayout.ColumnCount = 4
$scheduleLayout.RowCount = 9
$scheduleLayout.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 8)
[void]$scheduleLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$scheduleLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
[void]$scheduleLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$scheduleLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 125)))
1..5 | ForEach-Object { [void]$scheduleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) }
[void]$scheduleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$scheduleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
[void]$scheduleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
[void]$scheduleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
$scheduleGroup.Controls.Add($scheduleLayout)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '启用状态' -Bold), 0, 0)
$taskToggleButton = New-Object System.Windows.Forms.CheckBox
$taskToggleButton.Appearance = [System.Windows.Forms.Appearance]::Button
$taskToggleButton.AutoCheck = $false
$taskToggleButton.Checked = $true
$taskToggleButton.Text = '运行计划：已开启'
$taskToggleButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$taskToggleButton.Size = New-Object System.Drawing.Size(180, 30)
$taskToggleButton.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$taskToggleButton.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 4)
$taskToggleButton.AccessibleName = '运行计划开关'
$taskToggleButton.AccessibleDescription = '切换后立即启用或停用计划任务并保存状态，但不会按需运行任务。'
$scheduleLayout.Controls.Add($taskToggleButton, 1, 0)
$scheduleLayout.SetColumnSpan($taskToggleButton, 3)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '即时控制' -Bold), 0, 1)
$instantDeliveryButton = New-Object System.Windows.Forms.Button
$instantDeliveryButton.Text = '马上开始'
$instantDeliveryButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$instantDeliveryButton.Size = New-Object System.Drawing.Size(120, 30)
$instantDeliveryButton.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$instantDeliveryButton.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 4)
$instantDeliveryButton.AccessibleName = '即时投递开关'
$instantDeliveryButton.AccessibleDescription = '在正常时段内临时停止至下个时段；在非运行时段立即开始至正常时段接管。'
$scheduleLayout.Controls.Add($instantDeliveryButton, 1, 1)
$instantDeliveryHint = New-CfnLayoutLabel '' -TopMargin 5
$instantDeliveryHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$instantDeliveryHint.AutoEllipsis = $true
$instantDeliveryHint.Dock = [System.Windows.Forms.DockStyle]::Fill
$scheduleLayout.Controls.Add($instantDeliveryHint, 2, 1)
$scheduleLayout.SetColumnSpan($instantDeliveryHint, 2)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '每日时间窗'), 0, 2)
$timePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$timePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$timePanel.WrapContents = $false
$timePanel.Margin = New-Object System.Windows.Forms.Padding(0)
$timePanel.Controls.Add((New-CfnLayoutLabel '开始' -TopMargin 5))
$startPicker = New-Object System.Windows.Forms.DateTimePicker
$startPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$startPicker.CustomFormat = 'HH:mm'
$startPicker.ShowUpDown = $true
$startPicker.Size = New-Object System.Drawing.Size(90, 25)
$startPicker.Margin = New-Object System.Windows.Forms.Padding(0, 3, 18, 3)
$timePanel.Controls.Add($startPicker)
$timePanel.Controls.Add((New-CfnLayoutLabel '结束' -TopMargin 5))
$endPicker = New-Object System.Windows.Forms.DateTimePicker
$endPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$endPicker.CustomFormat = 'HH:mm'
$endPicker.ShowUpDown = $true
$endPicker.Size = New-Object System.Drawing.Size(90, 25)
$endPicker.Margin = New-Object System.Windows.Forms.Padding(0, 3, 3, 3)
$timePanel.Controls.Add($endPicker)
$scheduleLayout.Controls.Add($timePanel, 1, 2)
$scheduleLayout.SetColumnSpan($timePanel, 3)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '轮询与队列'), 0, 3)
$intervalPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$intervalPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$intervalPanel.WrapContents = $false
$intervalPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$intervalPanel.Controls.Add((New-CfnLayoutLabel '检查间隔（分钟）' -TopMargin 5))
$intervalNumber = New-Object System.Windows.Forms.NumericUpDown
$intervalNumber.Minimum = 1
$intervalNumber.Maximum = 60
$intervalNumber.Size = New-Object System.Drawing.Size(70, 25)
$intervalNumber.Margin = New-Object System.Windows.Forms.Padding(0, 3, 18, 3)
$intervalPanel.Controls.Add($intervalNumber)
$intervalPanel.Controls.Add((New-CfnLayoutLabel '队列保留（小时）' -TopMargin 5))
$maxQueueNumber = New-Object System.Windows.Forms.NumericUpDown
$maxQueueNumber.Minimum = 1
$maxQueueNumber.Maximum = 720
$maxQueueNumber.Size = New-Object System.Drawing.Size(75, 25)
$maxQueueNumber.Margin = New-Object System.Windows.Forms.Padding(0, 3, 3, 3)
$intervalPanel.Controls.Add($maxQueueNumber)
$scheduleLayout.Controls.Add($intervalPanel, 1, 3)
$scheduleLayout.SetColumnSpan($intervalPanel, 3)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '节假日模式'), 0, 4)
$holidayRegionCombo = New-Object System.Windows.Forms.ComboBox
$holidayRegionCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$holidayRegionCombo.Items.AddRange(@('Auto', 'SG', 'CN', 'None', 'Custom'))
$holidayRegionCombo.Dock = [System.Windows.Forms.DockStyle]::Fill
$scheduleLayout.Controls.Add($holidayRegionCombo, 1, 4)
$holidayHint = New-CfnLayoutLabel 'Auto/自动识别，SG/新加坡，CN/中国，None/关闭，Custom/自定义日历' -TopMargin 5
$holidayHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$holidayHint.AutoEllipsis = $true
$holidayHint.Dock = [System.Windows.Forms.DockStyle]::Fill
$scheduleLayout.Controls.Add($holidayHint, 2, 4)
$scheduleLayout.SetColumnSpan($holidayHint, 2)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '运行说明'), 0, 5)
$holidayModeExplanation = New-Object System.Windows.Forms.Label
$holidayModeExplanation.AutoSize = $false
$holidayModeExplanation.Dock = [System.Windows.Forms.DockStyle]::Fill
$holidayModeExplanation.MinimumSize = New-Object System.Drawing.Size(0, 30)
$holidayModeExplanation.Padding = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
$holidayModeExplanation.ForeColor = [System.Drawing.SystemColors]::GrayText
$scheduleLayout.Controls.Add($holidayModeExplanation, 1, 5)
$scheduleLayout.SetColumnSpan($holidayModeExplanation, 3)
$updateHolidayExplanationWidth = {
    $availableWidth = [int]($scheduleLayout.ClientSize.Width - $scheduleLayout.Padding.Horizontal - 120 - 12)
    if ($availableWidth -le 100 -or [string]::IsNullOrWhiteSpace($holidayModeExplanation.Text)) { return }
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor `
        [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor `
        [System.Windows.Forms.TextFormatFlags]::TextBoxControl
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
        $holidayModeExplanation.Text,
        $holidayModeExplanation.Font,
        (New-Object System.Drawing.Size($availableWidth, [int]::MaxValue)),
        $flags
    )
    $targetHeight = [math]::Max(30, $measured.Height + $holidayModeExplanation.Padding.Vertical)
    if ($holidayModeExplanation.MinimumSize.Height -ne $targetHeight) {
        # The row is AutoSize; changing the label's minimum height lets it
        # shrink back to one line or grow only when measured text wraps.
        $holidayModeExplanation.MinimumSize = New-Object System.Drawing.Size(0, $targetHeight)
        $holidayModeExplanation.Height = $targetHeight
        $scheduleLayout.PerformLayout()
    }
}
$scheduleLayout.Add_SizeChanged($updateHolidayExplanationWidth)
$holidayModeExplanation.Add_TextChanged($updateHolidayExplanationWidth)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '自定义日历'), 0, 6)
$calendarText = New-CfnTextBox 0 0 100
$calendarText.Dock = [System.Windows.Forms.DockStyle]::Fill
$scheduleLayout.Controls.Add($calendarText, 1, 6)
$scheduleLayout.SetColumnSpan($calendarText, 2)
$calendarBrowseButton = New-Object System.Windows.Forms.Button
$calendarBrowseButton.Text = '浏览…'
$calendarBrowseButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$calendarBrowseButton.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 5)
$scheduleLayout.Controls.Add($calendarBrowseButton, 3, 6)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '全天运行日' -Bold), 0, 7)
$allDayWeekdayHint = New-CfnLayoutLabel '可选；勾选后，相应星期会补齐每日时间窗之外的时段，可与节假日模式叠加。' -TopMargin 5
$allDayWeekdayHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$allDayWeekdayHint.Dock = [System.Windows.Forms.DockStyle]::Fill
$scheduleLayout.Controls.Add($allDayWeekdayHint, 1, 7)
$scheduleLayout.SetColumnSpan($allDayWeekdayHint, 3)

$scheduleLayout.Controls.Add((New-CfnLayoutLabel '每周'), 0, 8)
$weekdayPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$weekdayPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$weekdayPanel.WrapContents = $true
$weekdayPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$weekdayChecks = [ordered]@{}
$weekdayLabels = [ordered]@{
    Monday = '周一'
    Tuesday = '周二'
    Wednesday = '周三'
    Thursday = '周四'
    Friday = '周五'
    Saturday = '周六'
    Sunday = '周日'
}
foreach ($weekday in $weekdayLabels.Keys) {
    $weekdayCheck = New-Object System.Windows.Forms.CheckBox
    $weekdayCheck.Text = $weekdayLabels[$weekday]
    $weekdayCheck.AutoSize = $true
    $weekdayCheck.Margin = New-Object System.Windows.Forms.Padding(3, 7, 16, 3)
    $weekdayCheck.AccessibleName = "全天运行日：$($weekdayLabels[$weekday])"
    $weekdayChecks[$weekday] = $weekdayCheck
    $weekdayPanel.Controls.Add($weekdayCheck)
}
$scheduleLayout.Controls.Add($weekdayPanel, 1, 8)
$scheduleLayout.SetColumnSpan($weekdayPanel, 3)

$deliveryGroup = New-CfnSectionGroup '发送策略'
$basicStack.Controls.Add($deliveryGroup, 0, 1)
$deliveryFlow = New-CfnCheckFlow
$deliveryGroup.Controls.Add($deliveryFlow)
$deliveryFlow.Controls.Add((New-CfnLayoutLabel '格式' -TopMargin 5))
$messageFormatCombo = New-Object System.Windows.Forms.ComboBox
$messageFormatCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$messageFormatCombo.Items.AddRange(@('card', 'text'))
$messageFormatCombo.Size = New-Object System.Drawing.Size(100, 25)
$messageFormatCombo.Margin = New-Object System.Windows.Forms.Padding(0, 3, 22, 3)
$deliveryFlow.Controls.Add($messageFormatCombo)
$deliveryFlow.Controls.Add((New-CfnLayoutLabel '每轮尝试' -TopMargin 5))
$sendAttemptsNumber = New-Object System.Windows.Forms.NumericUpDown
$sendAttemptsNumber.Minimum = 1
$sendAttemptsNumber.Maximum = 5
$sendAttemptsNumber.Size = New-Object System.Drawing.Size(65, 25)
$sendAttemptsNumber.Margin = New-Object System.Windows.Forms.Padding(0, 3, 22, 3)
$deliveryFlow.Controls.Add($sendAttemptsNumber)
$deliveryFlow.Controls.Add((New-CfnLayoutLabel '重试间隔（秒）' -TopMargin 5))
$retryDelayNumber = New-Object System.Windows.Forms.NumericUpDown
$retryDelayNumber.Minimum = 0
$retryDelayNumber.Maximum = 30
$retryDelayNumber.Size = New-Object System.Drawing.Size(65, 25)
$retryDelayNumber.Margin = New-Object System.Windows.Forms.Padding(0, 3, 3, 3)
$deliveryFlow.Controls.Add($retryDelayNumber)

$maintenanceGroup = New-CfnSectionGroup '维护'
$basicStack.Controls.Add($maintenanceGroup, 0, 2)
$maintenanceFlow = New-CfnCheckFlow
$maintenanceGroup.Controls.Add($maintenanceFlow)
$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = '安装通知'
Set-CfnButtonLayout $installButton 105
$maintenanceFlow.Controls.Add($installButton)
$uninstallButton = New-Object System.Windows.Forms.Button
$uninstallButton.Text = '卸载通知'
Set-CfnButtonLayout $uninstallButton 105
$maintenanceFlow.Controls.Add($uninstallButton)
$maintenanceFlow.SetFlowBreak($uninstallButton, $true)
$maintenanceHint = New-CfnLayoutLabel '安装：首次部署或修复脚本、Hook、notify 与计划任务；卸载：移除集成并尽量恢复安装前状态。' -TopMargin 1
$maintenanceHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$maintenanceHint.AutoEllipsis = $true
$maintenanceFlow.Controls.Add($maintenanceHint)

$rulesTab = New-Object System.Windows.Forms.TabPage
$rulesTab.Text = '通知规则'
$rulesTab.Padding = New-Object System.Windows.Forms.Padding(10)
$rulesTab.AutoScroll = $true
$settingsTabs.TabPages.Add($rulesTab)

$rulesStack = New-Object System.Windows.Forms.TableLayoutPanel
$rulesStack.Dock = [System.Windows.Forms.DockStyle]::Top
$rulesStack.AutoSize = $true
$rulesStack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$rulesStack.ColumnCount = 1
$rulesStack.RowCount = 6
[void]$rulesStack.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
1..6 | ForEach-Object { [void]$rulesStack.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
$rulesTab.Controls.Add($rulesStack)

$feishuGroup = New-CfnSectionGroup '飞书通知总开关'
$feishuGroup.MinimumSize = New-Object System.Drawing.Size(0, 108)
$feishuFlow = New-CfnCheckFlow
$feishuGroup.Controls.Add($feishuFlow)
$rulesStack.Controls.Add($feishuGroup, 0, 0)
$feishuToggleButton = New-Object System.Windows.Forms.CheckBox
$feishuToggleButton.Appearance = [System.Windows.Forms.Appearance]::Button
$feishuToggleButton.AutoCheck = $false
$feishuToggleButton.Checked = $true
$feishuToggleButton.Text = '飞书通知：已开启'
$feishuToggleButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$feishuToggleButton.Size = New-Object System.Drawing.Size(180, 30)
$feishuToggleButton.Margin = New-Object System.Windows.Forms.Padding(3, 0, 18, 4)
$feishuToggleButton.AccessibleName = '飞书通知开关'
$feishuToggleButton.AccessibleDescription = '切换后立即打开或关闭 Codex 飞书通知并保存状态；不会关闭飞书应用。'
$feishuFlow.Controls.Add($feishuToggleButton)
$feishuFlow.SetFlowBreak($feishuToggleButton, $true)
$feishuHint = New-CfnLayoutLabel '单击后立即保存状态；关闭后 PC 通知继续，新事件不进入飞书队列，已有待发送项移入可恢复的 suppressed 目录。' -TopMargin 6
$feishuHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$feishuFlow.Controls.Add($feishuHint)

$filterGroup = New-CfnSectionGroup '过滤规则'
$filterFlow = New-CfnCheckFlow
$filterGroup.Controls.Add($filterFlow)
$rulesStack.Controls.Add($filterGroup, 0, 1)
$visibleOnlyCheck = New-Object System.Windows.Forms.CheckBox
$visibleOnlyCheck.Text = '仅通知已登记在 Codex 桌面端的任务（推荐）'
$visibleOnlyCheck.AutoSize = $true
$visibleOnlyCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$filterFlow.Controls.Add($visibleOnlyCheck)
$skipBridgeCheck = New-Object System.Windows.Forms.CheckBox
$skipBridgeCheck.Text = '跳过由飞书桥接发起的回合（防回声）'
$skipBridgeCheck.AutoSize = $true
$filterFlow.Controls.Add($skipBridgeCheck)

$messageGroup = New-CfnSectionGroup '消息内容'
$messageFlow = New-CfnCheckFlow
$messageGroup.Controls.Add($messageFlow)
$rulesStack.Controls.Add($messageGroup, 0, 2)
$taskPreviewCheck = New-Object System.Windows.Forms.CheckBox
$taskPreviewCheck.Text = '包含任务摘要'
$taskPreviewCheck.AutoSize = $true
$taskPreviewCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$messageFlow.Controls.Add($taskPreviewCheck)
$resultPreviewCheck = New-Object System.Windows.Forms.CheckBox
$resultPreviewCheck.Text = '包含结果摘要'
$resultPreviewCheck.AutoSize = $true
$resultPreviewCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$messageFlow.Controls.Add($resultPreviewCheck)
$permissionToolCheck = New-Object System.Windows.Forms.CheckBox
$permissionToolCheck.Text = '显示等待授权的工具名'
$permissionToolCheck.AutoSize = $true
$messageFlow.Controls.Add($permissionToolCheck)

$lifecycleGroup = New-CfnSectionGroup '生命周期'
$lifecycleFlow = New-CfnCheckFlow
$lifecycleGroup.Controls.Add($lifecycleFlow)
$rulesStack.Controls.Add($lifecycleGroup, 0, 3)
$strictGateCheck = New-Object System.Windows.Forms.CheckBox
$strictGateCheck.Text = '严格完成门（Stop + 官方完成事件）'
$strictGateCheck.AutoSize = $true
$strictGateCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$lifecycleFlow.Controls.Add($strictGateCheck)
$permissionNotifyCheck = New-Object System.Windows.Forms.CheckBox
$permissionNotifyCheck.Text = '发送等待授权通知'
$permissionNotifyCheck.AutoSize = $true
$lifecycleFlow.Controls.Add($permissionNotifyCheck)

$desktopGroup = New-CfnSectionGroup 'PC 通知'
$desktopFlow = New-CfnCheckFlow
$desktopGroup.Controls.Add($desktopFlow)
$rulesStack.Controls.Add($desktopGroup, 0, 4)
$desktopEnabledCheck = New-Object System.Windows.Forms.CheckBox
$desktopEnabledCheck.Text = '启用'
$desktopEnabledCheck.AutoSize = $true
$desktopEnabledCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$desktopFlow.Controls.Add($desktopEnabledCheck)
$desktopBackgroundCheck = New-Object System.Windows.Forms.CheckBox
$desktopBackgroundCheck.Text = '仅 Codex 不在前台时'
$desktopBackgroundCheck.AutoSize = $true
$desktopBackgroundCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$desktopFlow.Controls.Add($desktopBackgroundCheck)
$desktopCompletionCheck = New-Object System.Windows.Forms.CheckBox
$desktopCompletionCheck.Text = '任务完成'
$desktopCompletionCheck.AutoSize = $true
$desktopCompletionCheck.Margin = New-Object System.Windows.Forms.Padding(3, 3, 24, 3)
$desktopFlow.Controls.Add($desktopCompletionCheck)
$desktopPermissionCheck = New-Object System.Windows.Forms.CheckBox
$desktopPermissionCheck.Text = '等待授权'
$desktopPermissionCheck.AutoSize = $true
$desktopFlow.Controls.Add($desktopPermissionCheck)

$safetyGroup = New-CfnSectionGroup '说明与安全边界'
$safetyGroup.AutoSize = $false
$safetyGroup.Height = 92
$rulesStack.Controls.Add($safetyGroup, 0, 5)
$safetyNote = New-Object System.Windows.Forms.Label
$safetyNote.Text = '飞书打开时按队列和计划任务发送，不跟随 Codex 是否在前台；飞书关闭时 PC 通知仍单独遵循前台规则。两个总开关只切换启用状态；“马上开始/立刻停止”只临时覆盖投递时段，不会修改长期计划，也不会自动批准、拒绝或继续 Codex 任务。'
$safetyNote.Dock = [System.Windows.Forms.DockStyle]::Fill
$safetyNote.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$safetyNote.ForeColor = [System.Drawing.SystemColors]::GrayText
$safetyGroup.Controls.Add($safetyNote)

$statusTab = New-Object System.Windows.Forms.TabPage
$statusTab.Text = '状态与检查结果'
$statusTab.Padding = New-Object System.Windows.Forms.Padding(10)
$settingsTabs.TabPages.Add($statusTab)
$statusText = New-Object System.Windows.Forms.TextBox
$statusText.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusText.Multiline = $true
$statusText.ReadOnly = $true
$statusText.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$statusText.WordWrap = $false
$statusText.BackColor = [System.Drawing.SystemColors]::Window
$statusText.Font = New-Object System.Drawing.Font('Consolas', 9)
$statusTab.Controls.Add($statusText)

$actionBar = New-Object System.Windows.Forms.FlowLayoutPanel
$actionBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$actionBar.AutoSize = $true
$actionBar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$actionBar.WrapContents = $true
$actionBar.Margin = New-Object System.Windows.Forms.Padding(0)
$actionBar.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$rootLayout.Controls.Add($actionBar, 0, 3)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = '应用设置'
Set-CfnButtonLayout $applyButton 105
$applyButton.BackColor = [System.Drawing.SystemColors]::Highlight
$applyButton.ForeColor = [System.Drawing.SystemColors]::HighlightText
$applyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$actionBar.Controls.Add($applyButton)
$validateButton = New-Object System.Windows.Forms.Button
$validateButton.Text = '检查配置'
Set-CfnButtonLayout $validateButton
$actionBar.Controls.Add($validateButton)
$reloadButton = New-Object System.Windows.Forms.Button
$reloadButton.Text = '重新加载'
Set-CfnButtonLayout $reloadButton
$actionBar.Controls.Add($reloadButton)
$logsButton = New-Object System.Windows.Forms.Button
$logsButton.Text = '打开日志'
Set-CfnButtonLayout $logsButton
$actionBar.Controls.Add($logsButton)
$schedulerButton = New-Object System.Windows.Forms.Button
$schedulerButton.Text = '任务计划程序'
Set-CfnButtonLayout $schedulerButton 125
$actionBar.Controls.Add($schedulerButton)
$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '关闭'
Set-CfnButtonLayout $closeButton
$actionBar.Controls.Add($closeButton)
$form.CancelButton = $closeButton

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($applyButton, '备份现有配置并重新注册任务；不会手动启动任务。')
$toolTip.SetToolTip($taskToggleButton, '单击后立即启用或停用计划任务并保存状态，但绝不会手动运行任务。')
$toolTip.SetToolTip($instantDeliveryButton, '非运行时段点击“马上开始”会立即隐藏投递一次并临时按间隔运行；运行中点击“立刻停止”会暂停至下个运行时段。')
$toolTip.SetToolTip($feishuToggleButton, '单击后立即打开或关闭 Codex 飞书通知并保存状态；不会关闭飞书应用，PC 通知不受影响。')
$toolTip.SetToolTip($chatIdText, '私有值，仅保存在被 Git 忽略的本地配置中。')
$toolTip.SetToolTip($larkCliText, '留空＝自动查找；只有自动检测失败时才需要手动指定。')
$toolTip.SetToolTip($larkCliResolutionLabel, '显示当前机器实际解析到的 lark-cli，不会把自动路径写死进配置。')
$toolTip.SetToolTip($profileCombo, '仅列出配置根目录下已经存在的 Lark profile。')
$toolTip.SetToolTip($requireProfileCheck, '取消后将使用 lark-cli 的默认认证配置，并禁用 profile 下拉列表。')
$toolTip.SetToolTip($strictGateCheck, 'Stop Hook 先登记，随后官方 agent-turn-complete 事件才允许完成通知入队。')
$toolTip.SetToolTip($desktopBackgroundCheck, '只控制本机 Windows 通知；飞书发送不受 Codex 前台状态影响。')
$toolTip.SetToolTip($weekdayPanel, '不勾选表示不设置固定的每周全天运行日；勾选后须点击“应用设置”才会重建计划任务。')
$toolTip.SetToolTip($installButton, '按当前界面配置首次安装或修复通知；会备份并验证，但不会启动计划任务，也不会绕过 Codex Hook 信任。')
$toolTip.SetToolTip($uninstallButton, '卸载本通知集成并恢复安装前的计划任务；设置、日志和队列会保留。')

$showChatCheck.Add_CheckedChanged({ $script:chatIdText.UseSystemPasswordChar = -not $script:showChatCheck.Checked })
$requireProfileCheck.Add_CheckedChanged({ Update-CfnProfileControls })
$channelHomeText.Add_TextChanged({ Update-CfnProfileChoices })
$desktopEnabledCheck.Add_CheckedChanged({ Update-CfnDesktopControls })
$holidayRegionCombo.Add_SelectedIndexChanged({ Update-CfnCalendarControls })
$calendarBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择节假日日历 JSON'
    $dialog.Filter = 'JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*'
    if ($script:calendarText.Text -and (Test-Path -LiteralPath $script:calendarText.Text)) {
        $dialog.InitialDirectory = Split-Path -Parent $script:calendarText.Text
    }
    if ($dialog.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:calendarText.Text = $dialog.FileName
    }
    $dialog.Dispose()
})
$larkCliBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择 lark-cli 可执行文件'
    $dialog.Filter = '可执行文件 (*.exe;*.cmd;*.ps1)|*.exe;*.cmd;*.ps1|所有文件 (*.*)|*.*'
    if ($script:larkCliText.Text -and (Test-Path -LiteralPath $script:larkCliText.Text)) {
        $dialog.InitialDirectory = Split-Path -Parent $script:larkCliText.Text
    }
    if ($dialog.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:larkCliText.Text = $dialog.FileName
    }
    $dialog.Dispose()
})
$larkCliText.Add_TextChanged({ Update-CfnLarkCliResolution })
$validateButton.Add_Click({
    try {
        $selected = Get-CfnSelectedModel
        $validation = Test-CfnGuiModel $selected
        Show-CfnValidation $validation
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '配置检查失败', 'OK', 'Error')
    }
})
$reloadButton.Add_Click({
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:form,
            '重新加载会丢弃尚未应用的界面修改，是否继续？',
            '重新加载',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:model = Get-CfnGuiModel -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        Set-CfnControlsFromModel $script:model
        Update-CfnStatus
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '重新加载失败', 'OK', 'Error')
    }
})
$applyButton.Add_Click({
    Invoke-CfnGuiDeployment -Mode 'Apply'
})
$installButton.Add_Click({
    Invoke-CfnGuiDeployment -Mode 'Install'
})
$taskToggleButton.Add_Click({
    try {
        $status = Get-CfnGuiStatus -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        if (-not $status.TaskExists) { throw '计划任务不存在。' }
        $newEnabled = -not [bool]$status.ScheduleEnabled
        if (-not $newEnabled) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $script:form,
                '关闭运行计划后，飞书新事件仍可能进入待发送队列，但不会发送；重新开启后可能补发保留期内的项目。PC 通知不受影响。是否继续？',
                '关闭运行计划',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        Set-CfnBusy $true
        Clear-CfnGuiManualDeliveryOverride -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        if ($newEnabled) {
            Enable-ScheduledTask -TaskName $script:target.TaskName -ErrorAction Stop | Out-Null
        } else {
            if ([string]$status.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $script:target.TaskName -ErrorAction SilentlyContinue
            }
            Disable-ScheduledTask -TaskName $script:target.TaskName -ErrorAction Stop | Out-Null
        }
        $script:model.ScheduleEnabled = $newEnabled
        Set-CfnScheduleToggleState $newEnabled
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '任务操作失败', 'OK', 'Error')
    } finally {
        Set-CfnBusy $false
        Update-CfnStatus
    }
})
$instantDeliveryButton.Add_Click({
    try {
        Set-CfnBusy $true
        $outcome = Invoke-CfnGuiManualDeliveryToggle -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        $script:statusText.Text = switch ([string]$outcome.Action) {
            'paused' { '已立刻停止投递；将在 {0} 自动恢复，或再次点击“马上开始”。' -f (Format-CfnDateTime $outcome.ExpiresAt) }
            'forced' { "已马上开始投递；将在 $(Format-CfnDateTime $outcome.ExpiresAt) 交回正常运行时段。" }
            default { '已恢复当前正常运行时段，并立即启动了一次隐藏投递。' }
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '即时控制失败', 'OK', 'Error')
    } finally {
        Set-CfnBusy $false
        Update-CfnStatus
    }
})
$feishuToggleButton.Add_Click({
    try {
        $status = Get-CfnGuiStatus -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName
        if (-not $status.SettingsExists) { throw '受管配置不存在，请先应用一次完整设置。' }
        $newEnabled = -not [bool]$status.FeishuEnabled
        if (-not $newEnabled) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $script:form,
                '关闭后，新的 Codex 事件不会进入飞书队列；当前待发送项会移入 suppressed 目录，不会在重新打开后补发。PC 通知保持原设置。是否继续？',
                '立即关闭飞书通知',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        Set-CfnBusy $true
        $outcome = Set-CfnGuiFeishuEnabled -InstallRoot $script:target.InstallRoot -Enabled $newEnabled
        $script:model.FeishuEnabled = $newEnabled
        Set-CfnFeishuToggleState $newEnabled
        $message = if ($newEnabled) {
            '飞书通知已打开。只会处理打开后的新事件；suppressed 目录中的旧项目不会自动补发。计划任务没有被手动运行。'
        } else {
            "飞书通知已关闭，PC 通知不受影响。已移入 suppressed 目录：$($outcome.SuppressedCount) 项。"
        }
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $message, '飞书通知开关', 'OK', 'Information')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '飞书通知操作失败', 'OK', 'Error')
    } finally {
        Set-CfnBusy $false
        Update-CfnStatus
    }
})
$logsButton.Add_Click({
    $path = Join-Path $script:target.InstallRoot 'logs'
    if (Test-Path -LiteralPath $path -PathType Container) {
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path) | Out-Null
    } else {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, "日志目录尚不存在：`r`n$path", '打开日志', 'OK', 'Information')
    }
})
$schedulerButton.Add_Click({ Start-Process taskschd.msc | Out-Null })
$uninstallButton.Add_Click({
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:form,
            "将卸载本项目的 Codex 飞书通知：移除本项目拥有的 notify/生命周期 Hook，并恢复安装前备份的计划任务。设置、日志和队列会保留。`r`n`r`n是否继续？",
            '确认卸载通知',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Set-CfnBusy $true
        $output = (& $script:uninstallerPath -InstallRoot $script:target.InstallRoot -TaskName $script:target.TaskName `
            -RestorePreviousTask -Confirm:$false 2>&1 | Out-String).Trim()
        $script:statusText.Text = $output
        [void][System.Windows.Forms.MessageBox]::Show(
            $script:form,
            '通知集成已卸载。现有数据仍保留，请重新开启 Codex 让 Hook 变化完全生效。',
            '卸载通知完成',
            'OK',
            'Information'
        )
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '卸载通知失败', 'OK', 'Error')
    } finally {
        Set-CfnBusy $false
        Update-CfnStatus
    }
})
$closeButton.Add_Click({ $script:form.Close() })

$script:form = $form
$script:target = $target
$script:model = $model
$script:taskNameText = $taskNameText
$script:installRootText = $installRootText
$script:sourceLabel = $sourceLabel
$script:chatIdText = $chatIdText
$script:showChatCheck = $showChatCheck
$script:larkCliText = $larkCliText
$script:larkCliResolutionLabel = $larkCliResolutionLabel
$script:channelHomeText = $channelHomeText
$script:profileCombo = $profileCombo
$script:requireProfileCheck = $requireProfileCheck
$script:sendAttemptsNumber = $sendAttemptsNumber
$script:retryDelayNumber = $retryDelayNumber
$script:visibleOnlyCheck = $visibleOnlyCheck
$script:skipBridgeCheck = $skipBridgeCheck
$script:strictGateCheck = $strictGateCheck
$script:permissionNotifyCheck = $permissionNotifyCheck
$script:desktopEnabledCheck = $desktopEnabledCheck
$script:desktopBackgroundCheck = $desktopBackgroundCheck
$script:desktopCompletionCheck = $desktopCompletionCheck
$script:desktopPermissionCheck = $desktopPermissionCheck
$script:startPicker = $startPicker
$script:endPicker = $endPicker
$script:intervalNumber = $intervalNumber
$script:maxQueueNumber = $maxQueueNumber
$script:holidayRegionCombo = $holidayRegionCombo
$script:holidayModeExplanation = $holidayModeExplanation
$script:calendarText = $calendarText
$script:calendarBrowseButton = $calendarBrowseButton
$script:weekdayChecks = $weekdayChecks
$script:taskPreviewCheck = $taskPreviewCheck
$script:resultPreviewCheck = $resultPreviewCheck
$script:permissionToolCheck = $permissionToolCheck
$script:messageFormatCombo = $messageFormatCombo
$script:statusText = $statusText
$script:settingsTabs = $settingsTabs
$script:scheduleTab = $scheduleTab
$script:statusTab = $statusTab
$script:applyButton = $applyButton
$script:validateButton = $validateButton
$script:reloadButton = $reloadButton
$script:taskToggleButton = $taskToggleButton
$script:instantDeliveryButton = $instantDeliveryButton
$script:instantDeliveryHint = $instantDeliveryHint
$script:feishuToggleButton = $feishuToggleButton
$script:installButton = $installButton
$script:uninstallButton = $uninstallButton
$script:installerPath = $installerPath
$script:uninstallerPath = $uninstallerPath
$script:testConfigurationPath = $testConfigurationPath

Set-CfnControlsFromModel $model
if ($SmokeTest) {
    Update-CfnStatus
    [void]$form.Handle
    $form.ClientSize = New-Object System.Drawing.Size(680, 520)
    $settingsTabs.SelectedTab = $scheduleTab
    $form.ShowInTaskbar = $false
    $form.Opacity = 0
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $form.PerformLayout()
    $rootLayout.PerformLayout()
    $settingsTabs.PerformLayout()
    $scheduleTab.PerformLayout()
    $scheduleLayout.PerformLayout()
    [System.Windows.Forms.Application]::DoEvents()
    $actionBar.PerformLayout()
    $actionRows = @($actionBar.Controls | ForEach-Object { $_.Top } | Sort-Object -Unique).Count
    $buttonBottom = ($actionBar.Controls | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum
    $compactHolidayExplanationHeight = $holidayModeExplanation.Height
    $form.ClientSize = New-Object System.Drawing.Size(1100, 520)
    [System.Windows.Forms.Application]::DoEvents()
    $wideHolidayExplanationHeight = $holidayModeExplanation.Height
    $form.ClientSize = New-Object System.Drawing.Size(680, 520)
    [System.Windows.Forms.Application]::DoEvents()
    $initialRequireProfile = $requireProfileCheck.Checked
    $requireProfileCheck.Checked = $false
    $profileDisabledWhenUnchecked = -not $profileCombo.Enabled
    $requireProfileCheck.Checked = $initialRequireProfile
    $initialFeishuEnabled = $feishuToggleButton.Checked
    Set-CfnFeishuToggleState $false
    $feishuClosedStateValid = (-not $feishuToggleButton.Checked) -and ($feishuToggleButton.Text -eq '飞书通知：已关闭')
    Set-CfnFeishuToggleState $true
    $feishuOpenStateValid = $feishuToggleButton.Checked -and ($feishuToggleButton.Text -eq '飞书通知：已开启')
    Set-CfnFeishuToggleState $initialFeishuEnabled
    $initialDesktopEnabled = $desktopEnabledCheck.Checked
    $desktopEnabledCheck.Checked = $false
    $desktopDependentsDisabled = -not ($desktopBackgroundCheck.Enabled -or $desktopCompletionCheck.Enabled -or $desktopPermissionCheck.Enabled)
    $desktopEnabledCheck.Checked = $true
    $desktopDependentsEnabled = $desktopBackgroundCheck.Enabled -and $desktopCompletionCheck.Enabled -and $desktopPermissionCheck.Enabled
    $desktopEnabledCheck.Checked = $initialDesktopEnabled
    [pscustomobject]@{
        form_title = $form.Text
        control_count = $form.Controls.Count
        layout_mode = 'adaptive-tabs'
        resizable = ($form.FormBorderStyle -eq [System.Windows.Forms.FormBorderStyle]::Sizable)
        tab_count = $settingsTabs.TabPages.Count
        connection_tab_text = $basicTab.Text
        schedule_tab_text = $scheduleTab.Text
        basic_tab_scrolls = $basicTab.AutoScroll
        schedule_tab_scrolls = $scheduleTab.AutoScroll
        rules_tab_scrolls = $rulesTab.AutoScroll
        minimum_width = $form.MinimumSize.Width
        minimum_height = $form.MinimumSize.Height
        compact_client_width = $form.ClientSize.Width
        compact_client_height = $form.ClientSize.Height
        compact_tab_height = $settingsTabs.Height
        compact_action_rows = $actionRows
        compact_action_bar_fits = ([int]$buttonBottom -le $actionBar.ClientSize.Height)
        schedule_enabled = $taskToggleButton.Checked
        schedule_toggle_text = $taskToggleButton.Text
        schedule_toggle_single_control = $true
        instant_delivery_button_text = $instantDeliveryButton.Text
        instant_delivery_button_enabled = $instantDeliveryButton.Enabled
        instant_delivery_hint = $instantDeliveryHint.Text
        feishu_enabled = $feishuToggleButton.Checked
        feishu_toggle_text = $feishuToggleButton.Text
        feishu_toggle_single_control = $true
        feishu_toggle_state_roundtrip = ($feishuClosedStateValid -and $feishuOpenStateValid)
        manual_schedule_toggle = [bool]$taskToggleButton
        manual_feishu_toggle = [bool]$feishuToggleButton
        install_button_text = $installButton.Text
        install_button_in_basic_tab = ($installButton.Parent -eq $maintenanceFlow -and $maintenanceGroup.Parent -eq $basicStack)
        uninstall_button_text = $uninstallButton.Text
        uninstall_button_in_basic_tab = ($uninstallButton.Parent -eq $maintenanceFlow -and $maintenanceGroup.Parent -eq $basicStack)
        holiday_mode_explanation = $holidayModeExplanation.Text
        holiday_explanation_auto_height = ($scheduleLayout.RowStyles[5].SizeType -eq [System.Windows.Forms.SizeType]::AutoSize -and -not $holidayModeExplanation.AutoSize)
        holiday_explanation_height = $holidayModeExplanation.Height
        holiday_explanation_min_height = $holidayModeExplanation.MinimumSize.Height
        holiday_explanation_compact_height = $compactHolidayExplanationHeight
        holiday_explanation_wide_height = $wideHolidayExplanationHeight
        holiday_explanation_reflows = ($compactHolidayExplanationHeight -gt $wideHolidayExplanationHeight -and $wideHolidayExplanationHeight -eq 30)
        schedule_layout_height = $scheduleLayout.Height
        weekday_checkbox_count = $weekdayChecks.Count
        selected_all_day_weekdays = @($weekdayChecks.Keys | Where-Object { $weekdayChecks[$_].Checked })
        task_name = $target.TaskName
        install_root = $target.InstallRoot
        source = $model.Source
        source_display = $sourceLabel.Text
        lark_cli_cue = '留空＝自动查找'
        lark_cli_resolution = $larkCliResolutionLabel.Text
        profile_control = $profileCombo.GetType().Name
        profile_dropdown_style = [string]$profileCombo.DropDownStyle
        profile_choices = @($profileCombo.Items | ForEach-Object { [string]$_ })
        selected_profile = [string]$profileCombo.SelectedItem
        require_profile = $requireProfileCheck.Checked
        profile_control_enabled = $profileCombo.Enabled
        profile_disabled_when_unchecked = $profileDisabledWhenUnchecked
        desktop_dependents_disabled_when_off = $desktopDependentsDisabled
        desktop_dependents_enabled_when_on = $desktopDependentsEnabled
    } | ConvertTo-Json
    $form.Dispose()
    exit 0
}
$form.Add_Shown({
    $workingArea = [System.Windows.Forms.Screen]::FromControl($script:form).WorkingArea
    $availableWidth = [math]::Max(520, $workingArea.Width - 32)
    $availableHeight = [math]::Max(420, $workingArea.Height - 32)
    $script:form.MinimumSize = New-Object System.Drawing.Size(
        [math]::Min(680, $availableWidth),
        [math]::Min(520, $availableHeight)
    )
    if ($script:form.Width -gt $availableWidth) { $script:form.Width = $availableWidth }
    if ($script:form.Height -gt $availableHeight) { $script:form.Height = $availableHeight }
    $script:form.Left = $workingArea.Left + [math]::Max(0, [int](($workingArea.Width - $script:form.Width) / 2))
    $script:form.Top = $workingArea.Top + [math]::Max(0, [int](($workingArea.Height - $script:form.Height) / 2))
    Update-CfnStatus
    $script:form.Activate()
})
[void]$form.ShowDialog()
$form.Dispose()
