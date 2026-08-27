[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $InstallRoot = (Join-Path $env:USERPROFILE '.codex\integrations\codex-feishu-notify'),
    [string] $TaskName = 'Codex.FeishuNotify',
    [switch] $RestorePreviousTask,
    [switch] $RemoveData,
    [switch] $ForceConfigRestore,
    [switch] $ForceHooksRestore
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
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

function Get-NotifyLineRecord {
    param([string] $Text)
    $match = [regex]::Match($Text, '(?m)^(?<line>[ \t]*notify[ \t]*=[^\r\n]*)(?<ending>\r?\n|$)')
    if (-not $match.Success) { return [pscustomobject]@{ Found = $false; Line = ''; Match = $null } }
    return [pscustomobject]@{ Found = $true; Line = $match.Groups['line'].Value; Match = $match }
}

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

if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
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
    $configText = Get-Content -LiteralPath $configPath -Raw
    $record = Get-NotifyLineRecord $configText
    $safeToRestore = $record.Found -and ($record.Line -eq [string]$state.installed_notify_line)
    if ($safeToRestore -or $ForceConfigRestore) {
        if ($PSCmdlet.ShouldProcess($configPath, 'Restore previous Codex notify assignment')) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $configPath -Destination "$configPath.before-uninstall-$stamp.bak"
            if ($record.Found) {
                $replacement = [string]$state.original_notify_line
                $ending = $record.Match.Groups['ending'].Value
                $newText = $configText.Substring(0, $record.Match.Index) +
                    $(if ($replacement) { $replacement + $ending } else { '' }) +
                    $configText.Substring($record.Match.Index + $record.Match.Length)
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($configPath, $newText, $utf8NoBom)
            }
        }
    } else {
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
        Join-Path $env:USERPROFILE '.codex\hooks.json'
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
                    Write-Warning "hooks.json could not be safely edited and was left unchanged: $($_.Exception.Message)"
                }
            }
        }
    }
}

if ($RemoveData) {
    $allowedParent = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\integrations'))
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
