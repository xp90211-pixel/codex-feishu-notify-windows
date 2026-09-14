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
    $raw | Add-Member NoteProperty custom_metadata ([pscustomobject]@{ keep = '保留' })
    Write-CfnJsonAtomic $settingsPath $raw
    $taskBefore = Export-ScheduledTask -TaskName $testName
    $configHash = (Get-FileHash $configPath).Hash
    $hooksHash = (Get-FileHash $hooksPath).Hash
    & $installer -InstallRoot $installRoot -SettingsOnly -NoDesktopToast:$false -Confirm:$false
    $raw = Read-CfnUtf8File $settingsPath | ConvertFrom-Json
    Assert-Install ($raw.transport.timeout_seconds -eq 11 -and $raw.delivery.sent_marker_retention_days -eq 17 -and $raw.custom_metadata.keep -eq '保留') 'Saving reset unspecified configuration.'
    Assert-Install ((Export-ScheduledTask -TaskName $testName) -ceq $taskBefore) 'Saving an unrelated setting changed task XML.'
    Assert-Install ((Get-FileHash $configPath).Hash -eq $configHash -and (Get-FileHash $hooksPath).Hash -eq $hooksHash) 'Settings-only save rewrote Codex configuration or hooks.'

    $settingsHash = (Get-FileHash $settingsPath).Hash
    $global:CfnTestFailRegistration = $true
    $failed = $false
    try { & $installer -InstallRoot $installRoot -ScheduleStart '19:00' -Confirm:$false } catch { $failed = $true }
    Assert-Install $failed 'Injected deployment failure did not surface.'
    Assert-Install ((Get-FileHash $settingsPath).Hash -eq $settingsHash -and (Get-FileHash $configPath).Hash -eq $configHash -and (Get-FileHash $hooksPath).Hash -eq $hooksHash) 'Rollback did not restore exact configuration bytes.'
    Assert-Install ((Export-ScheduledTask -TaskName $testName) -ceq $taskBefore) 'Rollback did not restore task XML.'
    Assert-Install (-not (Get-CfnSettings $installRoot).ScheduleEnabled) 'Rollback re-enabled scheduled delivery.'

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
