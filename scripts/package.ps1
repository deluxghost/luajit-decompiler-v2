#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory, (Get-Location).ProviderPath)
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory must not already exist.' }

$executable = Join-Path $build 'luajit-decompiler-v2.exe'
$metadataPath = Join-Path $build 'build-info.json'
$license = Join-Path $source 'LICENSE'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -cne $metadata.source_commit) { throw 'Source checkout and build metadata do not match.' }
$executableHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
if ($executableHash -cne $metadata.executable_sha256) { throw 'Executable changed after building.' }
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { throw 'Upstream license is missing.' }

New-Item -ItemType Directory -Path $output | Out-Null
$archiveName = 'luajit-decompiler-v2-windows-x64.zip'
$archive = Join-Path $output $archiveName
Compress-Archive -LiteralPath @($executable, $metadataPath, $license) -DestinationPath $archive -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Value "$hash  $archiveName" -Encoding utf8NoBOM
Write-Output "Packaged $archive"
