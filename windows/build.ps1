# Build the exact executable included in the plugin using stock .NET Framework 4.8 reference assemblies.
param([Parameter(Mandatory=$true)][string] $Output)
$ErrorActionPreference = 'Stop'
$sdk = (dotnet --list-sdks | Where-Object { $_ -match '^8\.0\.416 \[' } | Select-Object -First 1)
if (-not $sdk) { throw 'Build requires .NET SDK 8.0.416' }
$csc = Join-Path ($sdk.Substring($sdk.IndexOf('[') + 1).TrimEnd(']')) '8.0.416/Roslyn/bincore/csc.dll'
$ref = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8'
$refs = 'mscorlib','System','System.Core','System.Drawing','System.Windows.Forms','System.Web.Extensions' | ForEach-Object { '/reference:' + (Join-Path $ref "$_.dll") }
$outputPath = [IO.Path]::GetFullPath($Output)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath))
dotnet $csc /nologo /noconfig /nostdlib+ /deterministic+ /optimize+ /target:winexe /platform:anycpu /codepage:65001 "/pathmap:$PSScriptRoot=/src" "/out:$outputPath" @refs (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE) { throw 'Windows setup build failed' }
