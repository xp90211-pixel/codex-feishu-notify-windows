[CmdletBinding()]
param([Parameter(Mandatory = $true)] [string] $PackagePath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot = Split-Path -Parent $PSScriptRoot
$manifest = @(Get-Content (Join-Path $projectRoot 'release-files.txt') -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
$archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $top = ''
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        $name = $entry.FullName.Replace('\', '/')
        $parts = $name.Split('/')
        if ($parts.Length -lt 2 -or $parts -contains '..' -or $parts -contains '.' -or $parts -contains '' -or $name -match '[:\\]') { throw 'Unsafe release entry.' }
        if (-not $top) { $top = $parts[0] }
        if ($parts[0] -cne $top) { throw 'Release contains multiple roots.' }
        $relative = ($parts[1..($parts.Length - 1)] -join '/')
        if ($manifest -cnotcontains $relative -or -not $seen.Add($relative)) { throw "Unexpected or duplicate release entry: $relative" }
        $stream = $entry.Open()
        try {
            if ($relative -eq 'src/vendor/Tommy.dll') {
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
                if ($hash -ne '2684b7eaaca463ddb08e8bf55f12b0d8bf0b02ee868cf6a7b0d3c42b4b53003d') { throw 'Unrecognized bundled TOML parser.' }
            } else {
                $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
                try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
                foreach ($pattern in @('\boc_[0-9a-f]{24,}\b', '\bsk-[A-Za-z0-9_-]{20,}\b', 'https://open\.feishu\.cn/open-apis/bot/v2/hook/[A-Za-z0-9_-]{10,}', ('C:\\Users\\' + [regex]::Escape($env:USERNAME) + '\\'))) {
                    if ($content -match $pattern) { throw "Potential private data in release entry: $relative" }
                }
            }
        } finally { $stream.Dispose() }
    }
    if ($seen.Count -ne $manifest.Count) { throw 'Release is missing manifest entries.' }
    [pscustomobject]@{ Valid = $true; Files = $seen.Count; Package = $PackagePath }
} finally { $archive.Dispose() }
