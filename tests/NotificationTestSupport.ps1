# Offline test support: compile the public sources, never use a live installation.
function Invoke-CfnFixtureProcess {
    param([string] $FileName, [string[]] $Arguments, [string] $InputJson = '')
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $FileName
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CfnNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($null -ne $start.PSObject.Properties['StandardInputEncoding']) {
        $start.StandardInputEncoding = New-Object Text.UTF8Encoding($false)
    }
    $child = [Diagnostics.Process]::Start($start)
    try {
        $output = $child.StandardOutput.ReadToEndAsync()
        $errorText = $child.StandardError.ReadToEndAsync()
        if ($InputJson) { $child.StandardInput.Write($InputJson) }
        $child.StandardInput.Close()
        if (-not $child.WaitForExit(30000)) { $child.Kill(); throw 'Offline fixture timed out.' }
        if ($child.ExitCode -ne 0) { throw ('Offline fixture failed: ' + $errorText.GetAwaiter().GetResult()) }
        return $output.GetAwaiter().GetResult()
    } finally { $child.Dispose() }
}

function New-CfnOfflineRuntime {
    param([string] $ProjectRoot, [string] $Root)
    New-Item -ItemType Directory -Path $Root | Out-Null
    foreach ($name in @('CodexFeishuNotify.psm1', 'CfnIdleReminder.psm1', 'hook.ps1', 'notify.ps1', 'drain.ps1')) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot "src\$name") -Destination $Root
    }
    Import-Module (Join-Path $ProjectRoot 'src\CodexFeishuNotify.Management.psm1') -Force -DisableNameChecking
    New-CfnNotificationHost -SourcePath (Join-Path $ProjectRoot 'src\notification-host.cs') -OutputPath (Join-Path $Root 'notification-host.exe')
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    [void](Invoke-CfnFixtureProcess $compiler @('/nologo', '/target:exe', ('/out:' + (Join-Path $Root 'fake-lark.exe')), (Join-Path $ProjectRoot 'tests\fixtures\FakeLarkCli.cs')))
}

function Remove-CfnOfflineRuntime {
    param([string] $Root)
    $resolved = [IO.Path]::GetFullPath($Root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolved).TrimEnd('\') -ne $temp -or
        -not (Split-Path -Leaf $resolved).StartsWith('cfn-notification-test-')) {
        throw 'Refusing to remove a path outside the isolated notification fixture.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
