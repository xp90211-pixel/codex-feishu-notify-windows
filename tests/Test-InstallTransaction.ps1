[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module ScheduledTasks
$projectRoot = Split-Path -Parent $PSScriptRoot
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testBase ('cfn-install-test-' + [guid]::NewGuid().ToString('N'))
$testName = 'Codex.FeishuNotify.TransactionTest.' + [guid]::NewGuid().ToString('N')
$savedCodexHome = $env:CODEX_HOME
$global:CfnTestFailRegistration = $false
function Assert-Install {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
# Inject a failure after registration, not just before it, so rollback must
# restore the original Task Scheduler XML as well as files and hooks.
function Register-ScheduledTask {
    [CmdletBinding()]
    param([string] $TaskName, $InputObject, [string] $Xml, [switch] $Force)
    $result = ScheduledTasks\Register-ScheduledTask @PSBoundParameters
    if ($global:CfnTestFailRegistration -and -not $Xml) {
        $global:CfnTestFailRegistration = $false
        throw 'Injected failure after task registration.'
    }
    return $result
}
try {
    $env:CODEX_HOME = Join-Path $testRoot '自定义 Codex'
    New-Item -ItemType Directory -Path $env:CODEX_HOME -Force | Out-Null
    $installRoot = Join-Path $env:CODEX_HOME 'integrations\fixture'
    $configPath = Join-Path $env:CODEX_HOME 'config.toml'
    $nl = [Environment]::NewLine
    $configBefore = (@('# 中文配置', "model = 'test-model'", '[features]', 'hooks = true', '') -join $nl)
    [IO.File]::WriteAllText($configPath, $configBefore, (New-Object Text.UTF8Encoding($false)))
    $installer = Join-Path $projectRoot 'scripts\Install.ps1'
    $uninstaller = Join-Path $projectRoot 'scripts\Uninstall.ps1'
    & $installer -InstallRoot $installRoot -TaskName $testName -HolidayRegion None -NoFeishuNotifications -NoDesktopToast -DisableScheduledTask -Confirm:$false
    Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
    $settingsPath = Join-Path $installRoot 'settings.local.json'
    $settings = Get-CfnSettings $installRoot
    $idlePath = Join-Path $installRoot 'idle-reminder.settings.json'
    $idleModulePath = Join-Path $installRoot 'CfnIdleReminder.psm1'
    Assert-Install ($settings.FreshNotificationsOnly -and (Test-Path -LiteralPath $idleModulePath)) 'New installation did not deploy fresh-only support.'
    $idle = Read-CfnUtf8File $idlePath | ConvertFrom-Json
    Assert-Install (-not $idle.enabled -and $idle.confirm_seconds -eq 5) 'Aggregate app-status monitoring must be opt-in.'
    Assert-Install (-not $settings.IncludeTaskPreview -and -not $settings.IncludeResultPreview -and -not $settings.FeishuEnabled) 'Installation privacy or channel defaults incorrect.'
    $parsed = ConvertFrom-CfnToml (Read-CfnUtf8File $configPath)
    Assert-Install ($parsed.HasKey('notify') -and -not $parsed['features'].HasKey('notify')) 'Installed notify is not at root.'
    $hooksPath = Join-Path $env:CODEX_HOME 'hooks.json'
    $hooks = Read-CfnUtf8File $hooksPath | ConvertFrom-Json
    foreach ($event in @('PermissionRequest', 'PostToolUse', 'UserPromptSubmit', 'SessionStart', 'Stop')) {
        Assert-Install (-not $hooks.hooks.$event[0].hooks[0].async) 'Lifecycle state hooks must be synchronous.'
    }
    $raw = Read-CfnUtf8File $settingsPath | ConvertFrom-Json
    $raw.transport.timeout_seconds = 11
    $raw.delivery.sent_marker_retention_days = 17
    $raw.delivery.fresh_notifications_only = $false
    $idle.enabled = $true
    $idle.confirm_seconds = 3
    Write-CfnJsonAtomic $idlePath $idle
    $raw | Add-Member NoteProperty custom_metadata ([pscustomobject]@{ keep = '保留' })
    Write-CfnJsonAtomic $settingsPath $raw
    $taskBefore = Export-ScheduledTask -TaskName $testName
    $configHash = (Get-FileHash $configPath).Hash
    $hooksHash = (Get-FileHash $hooksPath).Hash
    & $installer -InstallRoot $installRoot -SettingsOnly -NoDesktopToast:$false -Confirm:$false
    $raw = Read-CfnUtf8File $settingsPath | ConvertFrom-Json
    Assert-Install ($raw.transport.timeout_seconds -eq 11 -and $raw.delivery.sent_marker_retention_days -eq 17 -and $raw.custom_metadata.keep -eq '保留') 'Saving reset unspecified configuration.'
    Assert-Install (-not $raw.delivery.fresh_notifications_only -and (Read-CfnUtf8File $idlePath | ConvertFrom-Json).enabled -and
        (Read-CfnUtf8File $idlePath | ConvertFrom-Json).confirm_seconds -eq 3) 'Saving unrelated settings lost notification choices.'
    Assert-Install ((Export-ScheduledTask -TaskName $testName) -ceq $taskBefore) 'Saving an unrelated setting changed task XML.'
    Assert-Install ((Get-FileHash $configPath).Hash -eq $configHash -and (Get-FileHash $hooksPath).Hash -eq $hooksHash) 'Settings-only save rewrote Codex configuration or hooks.'

    # Simulate a published v0.6.0 PowerShell task and completion entry point.
    $legacyAction = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path -Argument ('-NoProfile -File "{0}"' -f (Join-Path $installRoot 'drain.ps1')) -WorkingDirectory $installRoot
    Set-ScheduledTask -TaskName $testName -Action $legacyAction | Out-Null
    $legacyLine = 'notify = ' + (ConvertTo-CfnTomlArray @((Get-Process -Id $PID).Path, '-File', (Join-Path $installRoot 'notify.ps1')))
    [IO.File]::WriteAllText($configPath, (Set-CfnNotifyLine (Read-CfnUtf8File $configPath) $legacyLine), (New-Object Text.UTF8Encoding($false)))
    & $installer -InstallRoot $installRoot -Confirm:$false
    Assert-Install ((Get-ScheduledTask -TaskName $testName).Actions[0].Execute -ceq (Join-Path $installRoot 'notification-host.exe')) 'Legacy task was not migrated to the no-console host.'
    $migrated = @(ConvertFrom-CfnNotifyLine (Get-CfnNotifyRecord (Read-CfnUtf8File $configPath)).Line)
    Assert-Install ($migrated.Count -eq 2 -and $migrated[1] -ceq 'notify') 'Legacy notify was not migrated.'
    $taskBefore = Export-ScheduledTask -TaskName $testName
    $configHash = (Get-FileHash $configPath).Hash
    $hooksHash = (Get-FileHash $hooksPath).Hash
    $hostHash = (Get-FileHash (Join-Path $installRoot 'notification-host.exe')).Hash
    $settingsHash = (Get-FileHash $settingsPath).Hash
    $idleHash = (Get-FileHash $idlePath).Hash
    $idleModuleHash = (Get-FileHash $idleModulePath).Hash
    $global:CfnTestFailRegistration = $true
    $failed = $false
    try { & $installer -InstallRoot $installRoot -ScheduleStart '19:00' -AllIdleReminder:$false -FreshNotificationsOnly -Confirm:$false } catch { $failed = $true }
    Assert-Install $failed 'Injected deployment failure did not surface.'
    Assert-Install ((Get-FileHash $settingsPath).Hash -eq $settingsHash -and (Get-FileHash $configPath).Hash -eq $configHash -and (Get-FileHash $hooksPath).Hash -eq $hooksHash) 'Rollback did not restore exact configuration bytes.'
    Assert-Install ((Export-ScheduledTask -TaskName $testName) -ceq $taskBefore) 'Rollback did not restore task XML.'
    Assert-Install ((Get-FileHash (Join-Path $installRoot 'notification-host.exe')).Hash -ceq $hostHash) 'Rollback did not restore the exact host binary.'
    Assert-Install (-not (Get-CfnSettings $installRoot).ScheduleEnabled) 'Rollback re-enabled scheduled delivery.'
    Assert-Install ((Get-FileHash $idlePath).Hash -ceq $idleHash -and (Get-FileHash $idleModulePath).Hash -ceq $idleModuleHash) 'Rollback changed the aggregate reminder module or preferences.'

    # A same-path installed custom calendar is valid; excessive calendars fail
    # before settings or task changes.
    $calendarPath = Join-Path $installRoot 'holidays.local.json'
    $calendar = [ordered]@{ schema = 1; region = 'Custom'; source = 'fixture'; holidays = @([ordered]@{ date = [datetime]::Today.AddDays(2).ToString('yyyy-MM-dd'); name = 'fixture' }); workdays = @() }
    Write-CfnJsonAtomic $calendarPath $calendar
    & $installer -InstallRoot $installRoot -HolidayCalendarPath $calendarPath -Confirm:$false
    Assert-Install (Test-Path $calendarPath) 'Same-path custom calendar copy failed.'
    $taskBefore = Export-ScheduledTask -TaskName $testName
    $settingsHash = (Get-FileHash $settingsPath).Hash
    $largeCalendarPath = Join-Path $testRoot 'large.json'
    $calendar.holidays = @(1..60 | ForEach-Object { @{ date = [datetime]::Today.AddDays($_).ToString('yyyy-MM-dd'); name = 'fixture' } })
    Write-CfnJsonAtomic $largeCalendarPath $calendar
    $failed = $false
    try { & $installer -InstallRoot $installRoot -HolidayCalendarPath $largeCalendarPath -Confirm:$false } catch { $failed = $true }
    Assert-Install ($failed -and (Get-FileHash $settingsPath).Hash -eq $settingsHash -and (Export-ScheduledTask -TaskName $testName) -ceq $taskBefore) 'Too many triggers must fail before mutation.'

    $customCodexHome = $env:CODEX_HOME
    try {
        # A freshly opened manager may not inherit the installer's CODEX_HOME.
        $env:CODEX_HOME = ''
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'scripts\Test-Configuration.ps1') -InstallRoot $installRoot | Out-Null
        Assert-Install ($LASTEXITCODE -eq 0) 'Diagnostics did not infer the stored custom Codex home and task.'
    } finally { $env:CODEX_HOME = $customCodexHome }

    # Simulate the existing GUI-subsystem launcher without ever executing it.
    $hostPath = Join-Path $installRoot 'notification-host.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\whoami.exe') -Destination $hostPath
    $hostAction = New-ScheduledTaskAction -Execute $hostPath -Argument 'drain' -WorkingDirectory $installRoot
    Set-ScheduledTask -TaskName $testName -Action $hostAction | Out-Null
    $hostTask = Get-ScheduledTask -TaskName $testName
    Assert-Install (Test-CfnTaskOwnership $hostTask $installRoot) 'Existing no-console host was not recognized.'
    Assert-Install (-not (Test-CfnTaskOwnership $hostTask (Join-Path $testRoot 'unrelated'))) 'Same-name host in another installation was incorrectly claimed.'
    Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.Gui.psm1') -Force -DisableNameChecking
    Assert-Install ((Get-CfnGuiTarget -TaskName $testName).InstallRoot -ceq $installRoot) 'GUI did not discover the no-console installation.'
    Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
    $nestedNotify = ConvertTo-Json -InputObject @($hostPath, 'notify') -Compress
    $wrapper = @('fixture-wrapper.exe', '--previous-notify', $nestedNotify)
    $wrapperLine = 'notify = ' + (ConvertTo-CfnTomlArray $wrapper)
    [IO.File]::WriteAllText($configPath, (Set-CfnNotifyLine (Read-CfnUtf8File $configPath) $wrapperLine), (New-Object Text.UTF8Encoding($false)))
    & $installer -InstallRoot $installRoot -Confirm:$false
    $hostTask = Get-ScheduledTask -TaskName $testName
    Assert-Install ($hostTask.Actions[0].Execute -ceq $hostPath -and $hostTask.Actions[0].Arguments -ceq 'drain') 'Upgrade discarded the no-console task launcher.'
    $actualWrapper = @(ConvertFrom-CfnNotifyLine (Get-CfnNotifyRecord (Read-CfnUtf8File $configPath)).Line)
    Assert-Install (($actualWrapper | ConvertTo-Json -Compress) -ceq ($wrapper | ConvertTo-Json -Compress)) 'Upgrade duplicated or discarded the existing notify wrapper.'
    Assert-Install (-not (Test-Path -LiteralPath (Join-Path $installRoot 'previous-notify.json'))) 'Upgrade chained the notifier to itself.'
    $hooks = Read-CfnUtf8File $hooksPath | ConvertFrom-Json
    foreach ($event in @('PermissionRequest', 'PostToolUse', 'UserPromptSubmit', 'SessionStart', 'Stop')) {
        $handler = $hooks.hooks.$event[0].hooks[0]
        Assert-Install (-not $handler.async -and $handler.commandWindows.StartsWith("& '")) 'Upgrade did not preserve no-console hooks with synchronous state ordering.'
    }
    & $installer -InstallRoot $installRoot -SettingsOnly -ScheduleStart '19:10' -Confirm:$false
    Assert-Install ((Get-ScheduledTask -TaskName $testName).Actions[0].Execute -ceq $hostPath) 'Saving a new schedule discarded the no-console launcher.'
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'scripts\Test-Configuration.ps1') -InstallRoot $installRoot | Out-Null
    Assert-Install ($LASTEXITCODE -eq 0) 'Diagnostics rejected the no-console notification paths.'
    & $installer -InstallRoot $installRoot -SettingsOnly -FreshNotificationsOnly -AllIdleReminder:$false -Confirm:$false
    Assert-Install ((Get-CfnSettings $installRoot).FreshNotificationsOnly -and -not (Read-CfnUtf8File $idlePath | ConvertFrom-Json).enabled) 'Explicit notification switches were not saved.'

    $failed = $false
    try { & $uninstaller -InstallRoot $installRoot -TaskName 'Unrelated.Task' -Confirm:$false } catch { $failed = $true }
    Assert-Install ($failed -and [bool](Get-ScheduledTask -TaskName $testName)) 'Uninstall must reject an unrelated explicit task.'
    & $uninstaller -InstallRoot $installRoot -Confirm:$false
    Assert-Install (-not (Get-ScheduledTask -TaskName $testName -ErrorAction SilentlyContinue)) 'Uninstall did not infer the manifest task.'
    Assert-Install ((Read-CfnUtf8File $configPath) -ceq $configBefore) 'Uninstall did not restore root TOML and Chinese content.'
    Write-Host 'PASS: isolated install/save/upgrade rollback, ownership, CODEX_HOME, and calendar transactions.'
} finally {
    $env:CODEX_HOME = $savedCodexHome
    Stop-ScheduledTask -TaskName $testName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $testName -Confirm:$false -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ((Split-Path -Parent $resolved).TrimEnd('\') -eq $testBase -and (Split-Path -Leaf $resolved).StartsWith('cfn-install-test-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
