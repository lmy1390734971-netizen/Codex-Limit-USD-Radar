[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($null -eq $compiler) { throw 'The .NET Framework C# compiler was not found.' }

# Build the launcher (no-console EXE host)
$launcherSource = Join-Path $PSScriptRoot 'launcher\TokenRader.Launcher.cs'
$launcherOutput = Join-Path $PSScriptRoot 'TokenRader.exe'
& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll /out:$launcherOutput $launcherSource
if ($LASTEXITCODE -ne 0) { throw "Launcher build failed with exit code $LASTEXITCODE" }
Write-Output "Built $launcherOutput"

# Build the JSONL indexer library (used by TokenRader.Core.psm1)
$indexerSource = Join-Path $PSScriptRoot 'indexer\TokenRader.Indexer.cs'
$indexerOutput = Join-Path $PSScriptRoot 'indexer\TokenRader.Indexer.dll'
& $compiler /nologo /target:library /reference:System.Web.Extensions.dll /optimize+ /out:$indexerOutput $indexerSource
if ($LASTEXITCODE -ne 0) { throw "Indexer build failed with exit code $LASTEXITCODE" }
Write-Output "Built $indexerOutput"
