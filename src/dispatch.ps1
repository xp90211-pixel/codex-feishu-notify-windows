param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $NotificationPayload
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $IntegrationRoot 'CodexFeishuNotify.psm1') -Force -DisableNameChecking
$currentPowerShell = try { (Get-Process -Id $PID -ErrorAction Stop).Path } catch { '' }
if (-not $currentPowerShell) {
    $currentPowerShell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
if (-not $currentPowerShell) {
    $currentPowerShell = Join-Path $PSHOME 'powershell.exe'
}

try {
    & $currentPowerShell -NoLogo -NoProfile -NonInteractive -File (Join-Path $IntegrationRoot 'notify.ps1') @NotificationPayload
} catch {
    Write-CfnLog $IntegrationRoot 'dispatch' 'project_hook_failed' '' $_.Exception.Message
}

$previousPath = Join-Path $IntegrationRoot 'previous-notify.json'
if (Test-Path -LiteralPath $previousPath) {
    try {
        $previous = @(Get-Content -LiteralPath $previousPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        if ($previous.Count -gt 0) {
            $executable = [string]$previous[0]
            $arguments = @()
            if ($previous.Count -gt 1) { $arguments += $previous[1..($previous.Count - 1)] }
            $arguments += $NotificationPayload
            & $executable @arguments
        }
    } catch {
        Write-CfnLog $IntegrationRoot 'dispatch' 'previous_hook_failed' '' $_.Exception.Message
    }
}

exit 0
