[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.0.0-test'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'The one-click installer smoke test requires Windows.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cfn-installer-test-$PID-" + [guid]::NewGuid().ToString('N'))
$outputDirectory = Join-Path $temporaryRoot 'output'
$installRoot = Join-Path $temporaryRoot 'install-root'
$programsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
$shortcutDirectory = Join-Path $programsDirectory 'Codex Feishu Notify'
$shortcutPath = Join-Path $shortcutDirectory 'Codex Feishu Notify Settings.lnk'
$shortcutExistedBeforeTest = Test-Path -LiteralPath $shortcutPath
$testShortcut = -not $shortcutExistedBeforeTest

function Invoke-TestInstaller {
    param([Parameter(Mandatory = $true)] [string] $InstallerPath)

    $argumentLine = '--install-root "{0}" --no-launch --quiet' -f $installRoot.Replace('"', '\"')
    if (-not $testShortcut) { $argumentLine += ' --no-shortcut' }
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $argumentLine -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Installer smoke test exited with code $($process.ExitCode)."
    }
}

function Invoke-RejectedInstaller {
    param([Parameter(Mandatory = $true)] [string] $InstallerPath)

    $argumentLine = '--install-root "{0}" --no-launch --no-shortcut --quiet' -f $installRoot.Replace('"', '\"')
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $argumentLine -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        throw 'An unsafe installer payload was accepted.'
    }
}

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $result = & (Join-Path $projectRoot 'scripts\New-OneClickInstaller.ps1') -Version $Version -OutputDirectory $outputDirectory
    foreach ($artifact in @($result.Package, $result.Installer, $result.Checksum)) {
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "Expected installer artifact is missing: $artifact"
        }
    }

    $expectedHash = ((Get-Content -LiteralPath $result.Checksum -Raw).Trim() -split '\s+')[0]
    $actualHash = (Get-FileHash -LiteralPath $result.Installer -Algorithm SHA256).Hash
    if ($expectedHash -ne $actualHash) {
        throw 'The one-click installer checksum does not match.'
    }

    Invoke-TestInstaller $result.Installer
    $installedDirectory = Join-Path $installRoot "CodexFeishuNotify\v$Version"
    foreach ($relativePath in @('Open-Settings.cmd', 'scripts\Settings-Gui.ps1', 'scripts\Install.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installedDirectory $relativePath) -PathType Leaf)) {
            throw "Installed payload is missing: $relativePath"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $installedDirectory 'settings.local.json')) {
        throw 'The one-click installer must not contain local settings.'
    }
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installedGuiPath = Join-Path $installedDirectory 'scripts\Settings-Gui.ps1'
    $guiSmokeOutput = @(& $windowsPowerShell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $installedGuiPath -SmokeTest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The installed graphical settings smoke test failed:`n$($guiSmokeOutput -join "`n")"
    }
    $guiSmokeResult = ($guiSmokeOutput -join "`n") | ConvertFrom-Json
    if (-not $guiSmokeResult.resizable -or $guiSmokeResult.layout_mode -ne 'adaptive-tabs') {
        throw 'The installed graphical settings tool did not complete its adaptive-layout smoke test.'
    }
    if ($testShortcut) {
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
            throw 'The one-click installer did not create its Start menu shortcut.'
        }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        try {
            if ($shortcut.TargetPath -notmatch '(?i)\\WindowsPowerShell\\v1\.0\\powershell\.exe$') {
                throw 'The Start menu shortcut does not target Windows PowerShell.'
            }
            if ($shortcut.Arguments -notlike "*$installedDirectory*Settings-Gui.ps1*") {
                throw 'The Start menu shortcut does not open the installed graphical settings tool.'
            }
            if ($shortcut.WorkingDirectory -ne $installedDirectory) {
                throw 'The Start menu shortcut has the wrong working directory.'
            }
        } finally {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    $stalePath = Join-Path $installedDirectory 'stale-test-file.txt'
    [System.IO.File]::WriteAllText($stalePath, 'stale')
    Invoke-TestInstaller $result.Installer
    if (Test-Path -LiteralPath $stalePath) {
        throw 'Reinstalling the same version must replace stale application files.'
    }

    Add-Type -AssemblyName System.IO.Compression
    $maliciousPackagePath = Join-Path $temporaryRoot 'malicious-payload.zip'
    $maliciousOutput = Join-Path $temporaryRoot 'malicious-output'
    New-Item -ItemType Directory -Path $maliciousOutput -Force | Out-Null
    $maliciousArchive = [System.IO.Compression.ZipFile]::Open($maliciousPackagePath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $maliciousEntry = $maliciousArchive.CreateEntry("codex-feishu-notify-windows-v$Version/../../escaped.txt")
        $writer = New-Object System.IO.StreamWriter($maliciousEntry.Open())
        try { $writer.Write('unsafe') } finally { $writer.Dispose() }
    } finally {
        $maliciousArchive.Dispose()
    }
    $maliciousResult = & (Join-Path $projectRoot 'scripts\New-OneClickInstaller.ps1') -Version $Version `
        -OutputDirectory $maliciousOutput -PackagePath $maliciousPackagePath
    Invoke-RejectedInstaller $maliciousResult.Installer
    if (Test-Path -LiteralPath (Join-Path $installRoot 'escaped.txt')) {
        throw 'An unsafe installer payload wrote outside its staging directory.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installedDirectory 'Open-Settings.cmd') -PathType Leaf)) {
        throw 'Rejecting an unsafe payload damaged the previously installed version.'
    }

    Write-Host "PASS: one-click installer v$Version built, extracted, reinstalled, and rejected path traversal." -ForegroundColor Green
} finally {
    if ($testShortcut -and -not $shortcutExistedBeforeTest -and (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    if ($testShortcut -and -not $shortcutExistedBeforeTest -and
        (Test-Path -LiteralPath $shortcutDirectory -PathType Container) -and
        @(Get-ChildItem -LiteralPath $shortcutDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $shortcutDirectory -Force
    }
    $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolvedTemporary).TrimEnd('\') -eq $resolvedTempRoot -and
        (Split-Path -Leaf $resolvedTemporary).StartsWith('cfn-installer-test-')) {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
