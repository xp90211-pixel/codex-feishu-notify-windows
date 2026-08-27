[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [string] $OutputDirectory = '',

    [string] $PackagePath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'The one-click installer can only be built on Windows.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$OutputDirectory = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory))
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

if (-not $PackagePath) {
    $packageResult = & (Join-Path $PSScriptRoot 'New-ReleasePackage.ps1') -Version $Version -OutputDirectory $OutputDirectory
    $PackagePath = $packageResult.Package
}
$PackagePath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PackagePath))
if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "Release package not found: $PackagePath"
}

$bootstrapperPath = Join-Path $projectRoot 'installer\Bootstrapper.cs'
$manifestPath = Join-Path $projectRoot 'installer\app.manifest'
foreach ($requiredPath in @($bootstrapperPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Installer build input is missing: $requiredPath"
    }
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compilerPath = @($compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
if ($compilerPath.Count -eq 0) {
    throw 'The .NET Framework C# compiler was not found.'
}
$compilerPath = $compilerPath[0]

$numericVersion = ($Version -split '-', 2)[0]
$assemblyVersion = "$numericVersion.0"
$installerName = "codex-feishu-notify-windows-v$Version-setup.exe"
$installerPath = Join-Path $OutputDirectory $installerName
$checksumPath = "$installerPath.sha256"
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cfn-installer-build-$PID-" + [guid]::NewGuid().ToString('N'))
$assemblyInfoPath = Join-Path $temporaryRoot 'AssemblyInfo.cs'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $assemblyInfo = @"
using System.Reflection;
[assembly: AssemblyTitle("Codex Feishu Notify Installer")]
[assembly: AssemblyDescription("Per-user launcher for the Codex Feishu notification settings tool")]
[assembly: AssemblyCompany("Codex Feishu Notify contributors")]
[assembly: AssemblyProduct("Codex Feishu Notify for Windows")]
[assembly: AssemblyCopyright("Released under the MIT License")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$Version")]
"@
    [System.IO.File]::WriteAllText($assemblyInfoPath, $assemblyInfo, $utf8NoBom)

    Remove-Item -LiteralPath $installerPath, $checksumPath -Force -ErrorAction SilentlyContinue
    $compilerArguments = @(
        '/nologo',
        '/target:winexe',
        '/platform:anycpu',
        '/optimize+',
        '/warnaserror+',
        "/out:$installerPath",
        "/win32manifest:$manifestPath",
        "/resource:$PackagePath,CodexFeishuNotify.Payload.zip",
        '/reference:System.Core.dll',
        '/reference:System.IO.Compression.dll',
        '/reference:System.IO.Compression.FileSystem.dll',
        '/reference:System.Windows.Forms.dll',
        '/reference:Microsoft.CSharp.dll',
        $bootstrapperPath,
        $assemblyInfoPath
    )
    $compilerOutput = @(& $compilerPath @compilerArguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Installer compilation failed:`n$($compilerOutput -join "`n")"
    }

    $hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText($checksumPath, "$hash  $installerName`n", $utf8NoBom)
    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath

    [pscustomobject]@{
        Version = $Version
        Package = $PackagePath
        Installer = $installerPath
        Checksum = $checksumPath
        Sha256 = $hash
        SignatureStatus = [string]$signature.Status
    }
} finally {
    $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolvedTemporary).TrimEnd('\') -eq $resolvedTempRoot -and
        (Split-Path -Leaf $resolvedTemporary).StartsWith('cfn-installer-build-')) {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
