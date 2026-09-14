[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $InstallRoot = '',
    [string] $TaskName = 'Codex.FeishuNotify',
    [switch] $RestorePreviousTask,
    [switch] $RemoveData,
    [switch] $ForceConfigRestore,
    [switch] $ForceHooksRestore
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\src\CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
if (-not $InstallRoot) { $InstallRoot = Join-Path (Get-CfnCodexHome) 'integrations\codex-feishu-notify' }
$InstallRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallRoot))
$statePath = Join-Path $InstallRoot 'install-state.json'
$state = if (Test-Path -LiteralPath $statePath) {
    Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $null }
$hookWasSkipped = $false
if ($null -ne $state) {
    $hookModeProperty = $state.PSObject.Properties['hook_mode']
    $hookWasSkipped = ($null -ne $hookModeProperty -and [string]$hookModeProperty.Value -eq 'skipped')
}

function Get-NotifyLineRecord { param([string] $Text); return Get-CfnNotifyRecord $Text }

function Test-CfnInstalledLifecycleHandler {
    param([AllowNull()] $Handler)
    if ($null -eq $Handler) { return $false }
    $property = $Handler.PSObject.Properties['commandWindows']
    $fallback = $Handler.PSObject.Properties['command']
    $command = if ($null -ne $property) { [string]$property.Value } elseif ($null -ne $fallback) { [string]$fallback.Value } else { '' }
    return $command.IndexOf((Join-Path $InstallRoot 'hook.ps1'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Remove-CfnInstalledLifecycleHooks {
    param([Parameter(Mandatory = $true)] $Document)
    if ($null -eq $Document.PSObject.Properties['hooks'] -or $null -eq $Document.hooks) { return $false }
    $changed = $false
    foreach ($eventName in @('PermissionRequest', 'PostToolUse', 'UserPromptSubmit', 'SessionStart', 'Stop')) {
        $eventProperty = $Document.hooks.PSObject.Properties[$eventName]
        if ($null -eq $eventProperty) { continue }
        $keptGroups = New-Object System.Collections.Generic.List[object]
        foreach ($group in @($eventProperty.Value)) {
            $handlers = @($group.hooks)
            $keptHandlers = @($handlers | Where-Object { -not (Test-CfnInstalledLifecycleHandler $_) })
            if ($keptHandlers.Count -ne $handlers.Count) { $changed = $true }
            if ($keptHandlers.Count -gt 0) {
                $group.hooks = $keptHandlers
                $keptGroups.Add($group)
            }
        }
        if ($keptGroups.Count -eq 0) {
            $Document.hooks.PSObject.Properties.Remove($eventName)
        } else {
            $eventProperty.Value = $keptGroups.ToArray()
        }
    }
    return $changed
}

if ($null -eq $state) { throw 'No installation manifest found. Nothing was uninstalled.' }
if ([IO.Path]::GetFullPath([string]$state.install_root) -ine $InstallRoot) { throw 'Installation manifest does not own this directory.' }
if (-not $PSBoundParameters.ContainsKey('TaskName')) { $TaskName = [string]$state.task_name }
if ($TaskName -cne [string]$state.task_name) { throw 'Task name does not match the installation manifest.' }
$ownedTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($ownedTask -and -not (Test-CfnTaskOwnership $ownedTask $InstallRoot)) { throw 'Task action does not belong to this installation; nothing was removed.' }
$detached = $true
if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
    if (Test-Path -LiteralPath (Join-Path $InstallRoot 'settings.local.json')) { Set-CfnDeliveryEnabled $InstallRoot $false }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if ($RestorePreviousTask -and $null -ne $state -and $state.task_backup -and (Test-Path -LiteralPath $state.task_backup)) {
        Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content -LiteralPath $state.task_backup -Raw) -Force | Out-Null
    }
}

$manualDeliveryStatePath = Join-Path $InstallRoot 'spool\state\manual-delivery.json'
if (Test-Path -LiteralPath $manualDeliveryStatePath -PathType Leaf) {
    if ($PSCmdlet.ShouldProcess($manualDeliveryStatePath, 'Remove temporary manual delivery override')) {
        Remove-Item -LiteralPath $manualDeliveryStatePath -Force
    }
}

if (-not $hookWasSkipped -and $null -ne $state -and $state.config_path -and (Test-Path -LiteralPath $state.config_path)) {
    $configPath = [string]$state.config_path
    $configText = Read-CfnUtf8File $configPath
    $record = Get-NotifyLineRecord $configText
    $safeToRestore = $record.Found -and ($record.Line -eq [string]$state.installed_notify_line)
    if ($safeToRestore -or $ForceConfigRestore) {
        if ($PSCmdlet.ShouldProcess($configPath, 'Restore previous Codex notify assignment')) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $configPath -Destination "$configPath.before-uninstall-$stamp.bak"
            if ($record.Found) {
                $newText = Set-CfnNotifyLine $configText ([string]$state.original_notify_line)
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($configPath, $newText, $utf8NoBom)
            }
        }
    } else {
        $detached = $false
        Write-Warning 'config.toml changed after installation; its notify line was left untouched. Use -ForceConfigRestore only after reviewing the diff.'
    }
}

$lifecycleMode = if ($null -ne $state -and $null -ne $state.PSObject.Properties['lifecycle_hooks']) {
    [string]$state.lifecycle_hooks
} else { 'skipped' }
if ($lifecycleMode -ne 'skipped' -and $null -ne $state) {
    $hooksPath = if ($null -ne $state.PSObject.Properties['hooks_path'] -and $state.hooks_path) {
        [string]$state.hooks_path
    } else {
        Join-Path (Get-CfnCodexHome) 'hooks.json'
    }
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($hooksPath, 'Remove only this notifier lifecycle hooks')) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $hooksPath -Destination "$hooksPath.before-uninstall-$stamp.bak"
            $hooksBackup = if ($null -ne $state.PSObject.Properties['hooks_backup']) { [string]$state.hooks_backup } else { '' }
            if ($ForceHooksRestore -and $hooksBackup -and (Test-Path -LiteralPath $hooksBackup -PathType Leaf)) {
                Copy-Item -LiteralPath $hooksBackup -Destination $hooksPath -Force
            } else {
                try {
                    $document = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $changed = Remove-CfnInstalledLifecycleHooks $document
                    if ($changed) {
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                        [System.IO.File]::WriteAllText($hooksPath, ($document | ConvertTo-Json -Depth 20), $utf8NoBom)
                    }
                } catch {
                    $detached = $false
                    Write-Warning "hooks.json could not be safely edited and was left unchanged: $($_.Exception.Message)"
                }
            }
        }
    }
}

if ($RemoveData) {
    if (-not $detached) { throw 'References to the notifier remain in Codex configuration. Data was retained.' }
    foreach ($referenceFile in @([string]$state.config_path, [string](Get-CfnProperty $state 'hooks_path' ''))) {
        if ($referenceFile -and (Test-Path -LiteralPath $referenceFile)) {
            $text = Read-CfnUtf8File $referenceFile
            if ($text.Replace('\\', '\').IndexOf($InstallRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw 'Configuration still references this installation. Data was retained.'
            }
        }
    }
    $allowedParent = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent ([string]$state.config_path)) 'integrations'))
    $resolvedParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $InstallRoot))
    if ($resolvedParent -ne $allowedParent -or $InstallRoot -eq $allowedParent) {
        throw "Refusing recursive removal outside the expected integrations directory: $InstallRoot"
    }
    if ($PSCmdlet.ShouldProcess($InstallRoot, 'Remove notifier files, settings, logs, and queued data')) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
} else {
    Write-Host "Task, notify hook, and owned lifecycle-hook handlers removed. Data retained at: $InstallRoot"
    Write-Host 'Rerun with -RemoveData only if you want to permanently remove settings, logs, and queue files.'
}
