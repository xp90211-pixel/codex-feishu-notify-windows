[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'src\CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testBase ('cfn-host-test-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $testRoot "启动 目录's"
$utf8 = New-Object Text.UTF8Encoding($true)
function Assert-Host {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-HostFixture {
    param([string[]] $Arguments)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $runtime 'notification-host.exe'
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CfnNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Host test timed out.' }
        return $process.ExitCode
    } finally { $process.Dispose() }
}
try {
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $hostPath = Join-Path $runtime 'notification-host.exe'
    New-CfnNotificationHost -SourcePath (Join-Path $projectRoot 'src\notification-host.cs') -OutputPath $hostPath
    $bytes = [IO.File]::ReadAllBytes($hostPath)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    Assert-Host ([BitConverter]::ToUInt16($bytes, $pe + 0x5c) -eq 2) 'The host must be compiled as a GUI subsystem executable.'
    $probe = @'
param([string] $NotificationPayload, [switch] $DryRun)
Add-Type 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
$record = @{ payload = $NotificationPayload; console = [ConsoleProbe]::GetConsoleWindow().ToInt64(); dry_run = [bool]$DryRun }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'probe.json'), ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
# Exercise concurrent pipe reads; a sequential stderr reader would deadlock.
[Console]::Out.Write(('x' * 100000))
[Console]::Error.Write(('y' * 100000))
exit 0
'@
    foreach ($name in @('notify.ps1', 'drain.ps1')) { [IO.File]::WriteAllText((Join-Path $runtime $name), $probe, $utf8) }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\dispatch.ps1') -Destination $runtime
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\CodexFeishuNotify.psm1') -Destination $runtime
    $payload = 'Unicode 中文, "quotes", $(& whoami), & | >, C:\folder with spaces\'
    foreach ($mode in @('notify', 'dispatch')) {
        Assert-Host ((Invoke-HostFixture @($mode, $payload)) -eq 0) "$mode host failed."
        $result = Get-Content -LiteralPath (Join-Path $runtime 'probe.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Host ($result.payload -ceq $payload) "$mode changed argument boundaries."
        Assert-Host ($result.console -eq 0) "$mode allocated a child console."
    }
    Assert-Host ((Invoke-HostFixture @('drain', '-DryRun')) -eq 0) 'Drain host failed.'
    $result = Get-Content -LiteralPath (Join-Path $runtime 'probe.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Host ($result.dry_run -and $result.console -eq 0) 'Drain lost DryRun or created a console.'
    $hashBefore = (Get-FileHash -LiteralPath (Join-Path $runtime 'probe.json')).Hash
    foreach ($argsCase in @(@('arbitrary', 'command'), @('drain', '-File'), @('notify'))) {
        Assert-Host ((Invoke-HostFixture $argsCase) -eq 64) 'The host accepted an unsupported entry point or argument.'
    }
    Assert-Host ((Get-FileHash -LiteralPath (Join-Path $runtime 'probe.json')).Hash -ceq $hashBefore) 'Rejected commands executed a script.'
    Write-Host 'PASS: GUI subsystem, console-free notify/drain/dispatch, Unicode argv, concurrent pipes, and argument allowlist.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ((Split-Path -Parent $resolved).TrimEnd('\') -eq $testBase -and (Split-Path -Leaf $resolved).StartsWith('cfn-host-test-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
