#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Building requires Windows, Visual Studio 2022 C++ tools, and the Windows SDK.' }

$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory, (Get-Location).ProviderPath)
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -cne $SourceCommit) { throw 'Source checkout does not match SourceCommit.' }
& git -C $source diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'Source checkout contains tracked changes.' }
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory must not already exist.' }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Visual Studio 2022 C++ tools were not found.' }
& (Join-Path $installation 'Common7/Tools/Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation

$compiler = (Get-Command cl.exe -CommandType Application).Source
$compilerVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
$units = @('main.cpp', 'ast/ast.cpp', 'bytecode/bytecode.cpp', 'bytecode/prototype.cpp', 'lua/lua.cpp') |
    ForEach-Object { Join-Path $source $_ }
$flags = @('/nologo', '/std:c++20', '/J', '/EHsc', '/O2', '/MT')
New-Item -ItemType Directory -Path $output | Out-Null
Push-Location -LiteralPath $output
try {
    & $compiler @flags @units /Fe:luajit-decompiler-v2.exe /link user32.lib comdlg32.lib
    if ($LASTEXITCODE -ne 0) { throw 'MSVC build failed.' }
} finally {
    Pop-Location
}

$executable = Join-Path $output 'luajit-decompiler-v2.exe'
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $executable
$start.WorkingDirectory = $output
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
[void]$start.ArgumentList.Add('-?')
$process = [Diagnostics.Process]::Start($start)
try {
    if (-not $process.WaitForExit(15000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Decompiler CLI startup timed out.'
    }
    if ($process.ExitCode -ne 0) { throw "Decompiler CLI startup failed with exit code $($process.ExitCode)." }
} finally {
    $process.Dispose()
}

$metadata = [ordered]@{
    source_repository = 'https://github.com/Aussiemon/luajit-decompiler-v2'
    source_commit = $SourceCommit
    architecture = 'x64'
    compiler = 'MSVC'
    compiler_version = $compilerVersion
    compiler_flags = $flags
    executable_sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
}
$metadata | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $output 'build-info.json') -Encoding utf8NoBOM
Write-Output "Built and checked $executable"
