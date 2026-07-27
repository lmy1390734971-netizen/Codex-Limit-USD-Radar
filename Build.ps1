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

$source = Join-Path $PSScriptRoot 'launcher\TokenRader.Launcher.cs'
$output = Join-Path $PSScriptRoot 'TokenRader.exe'
& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll /out:$output $source
if ($LASTEXITCODE -ne 0) { throw "Launcher build failed with exit code $LASTEXITCODE" }
Write-Output "Built $output"
