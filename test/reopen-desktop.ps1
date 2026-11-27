param([Parameter(Mandatory)][string] $DesktopExe)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or (Split-Path $env:CODEX_HOME -Parent | Split-Path -Leaf) -notmatch '^sworncard-test-[0-9a-f]{32}$') {throw 'Disposable runner required'}
$process = Start-Process $DesktopExe -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $process.Refresh()
        if ($process.HasExited) {throw 'Reopened Desktop exited before showing its window'}
        if ($process.MainWindowHandle -ne 0) {
            Write-Host 'Passed: reopened official Desktop with the saved personal configuration.'
            break
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) {throw 'Missing reopened Desktop window'}
} finally {
    if (!$process.HasExited) {
        $null = $process.CloseMainWindow()
        if (!$process.WaitForExit(5000)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            if (!$process.WaitForExit(5000)) {throw 'Reopened test Desktop did not close'}
        }
    }
}
