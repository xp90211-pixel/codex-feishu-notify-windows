[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [string] $OutputDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$OutputDirectory = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory))
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$packageName = "codex-feishu-notify-windows-v$Version"
$zipPath = Join-Path $OutputDirectory "$packageName.zip"
$checksumPath = "$zipPath.sha256"
$stagingBase = Join-Path ([System.IO.Path]::GetTempPath()) ("cfn-release-$PID-" + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingBase $packageName
$includedPaths = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'CONTRIBUTING.md',
    'CHANGELOG.md',
    'THIRD_PARTY_NOTICES.md',
    'Open-Settings.cmd',
    'config',
    'docs',
    'scripts',
    'src',
    'tests'
)

try {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($relativePath in $includedPaths) {
        $sourcePath = Join-Path $projectRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Release input is missing: $relativePath" }
        Copy-Item -LiteralPath $sourcePath -Destination $packageRoot -Recurse -Force
    }

    Remove-Item -LiteralPath $zipPath, $checksumPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($checksumPath, "$hash  $([System.IO.Path]::GetFileName($zipPath))`n", $utf8NoBom)

    [pscustomobject]@{
        Version = $Version
        Package = $zipPath
        Checksum = $checksumPath
        Sha256 = $hash
    }
} finally {
    $resolvedStaging = [System.IO.Path]::GetFullPath($stagingBase)
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolvedStaging).TrimEnd('\') -eq $resolvedTemp -and
        (Split-Path -Leaf $resolvedStaging).StartsWith('cfn-release-')) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
