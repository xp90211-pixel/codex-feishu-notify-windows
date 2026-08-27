[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP: Task Scheduler integration test requires Windows.' -ForegroundColor Yellow
    exit 0
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$testName = "Codex.FeishuNotify.ManualControlTest.$PID"
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempBase "cfn-manual-control-test-$PID"

function Assert-ManualControl {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Destination $testRoot
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\CodexFeishuNotify.Gui.psm1') -Destination $testRoot
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\drain.ps1') -Destination $testRoot
    Copy-Item -LiteralPath (Join-Path $projectRoot 'config\settings.example.json') -Destination (Join-Path $testRoot 'settings.local.json')

    Import-Module (Join-Path $testRoot 'CodexFeishuNotify.Gui.psm1') -Force -DisableNameChecking
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c exit 0'
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(18).AddMinutes(40))
    $taskSettings = New-ScheduledTaskSettingsSet -Hidden -DisallowDemandStart -StartWhenAvailable:$false
    Register-ScheduledTask -TaskName $testName -Action $action -Trigger $trigger -Settings $taskSettings -Force | Out-Null

    $testNow = [datetime]'2030-01-02 10:00'
    $started = Invoke-CfnGuiManualDeliveryToggle -InstallRoot $testRoot -TaskName $testName -Now $testNow -NoImmediateDrain
    $registered = Get-ScheduledTask -TaskName $testName
    $manualTriggers = @($registered.Triggers | Where-Object { [string]$_.Id -eq 'CodexFeishuNotify.ManualOverride' })
    Assert-ManualControl ($started.Action -eq 'forced' -and $started.EffectiveActive) 'Outside-window toggle did not create a force state.'
    Assert-ManualControl ($manualTriggers.Count -eq 1) 'Outside-window toggle did not register exactly one named temporary trigger.'

    $stopped = Invoke-CfnGuiManualDeliveryToggle -InstallRoot $testRoot -TaskName $testName -Now $testNow -NoImmediateDrain
    $registered = Get-ScheduledTask -TaskName $testName
    $manualTriggers = @($registered.Triggers | Where-Object { [string]$_.Id -eq 'CodexFeishuNotify.ManualOverride' })
    Assert-ManualControl ($stopped.Action -eq 'paused' -and -not $stopped.EffectiveActive) 'Second toggle did not create a pause state.'
    Assert-ManualControl ($manualTriggers.Count -eq 0) 'Stopping did not remove the named temporary trigger.'

    Clear-CfnGuiManualDeliveryOverride -InstallRoot $testRoot -TaskName $testName
    Write-Host 'PASS: temporary start/stop state and Task Scheduler trigger round-trip verified.' -ForegroundColor Green
} finally {
    Stop-ScheduledTask -TaskName $testName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $testName -Confirm:$false -ErrorAction SilentlyContinue
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ((Split-Path -Parent $resolvedTestRoot).TrimEnd('\') -eq $tempBase -and
        (Split-Path -Leaf $resolvedTestRoot) -eq "cfn-manual-control-test-$PID") {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
