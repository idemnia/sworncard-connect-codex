# Install the official desktop package in a disposable Windows test runner.
$ErrorActionPreference = 'Stop'
$msix = Join-Path $env:RUNNER_TEMP 'ChatGPT-x64.msix'
curl.exe --fail --silent --show-error --retry 2 --output $msix 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
if ($LASTEXITCODE) { throw 'Desktop package download failed' }
Add-AppxPackage -Path $msix
$app = Get-AppxPackage -Name OpenAI.Codex | Where-Object Publisher -eq 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
if (-not $app -or -not (Test-Path (Join-Path $app.InstallLocation 'app/resources/codex.exe'))) { throw 'Missing registered Codex Desktop' }
Write-Host "Registered Windows Desktop $($app.Version)"
