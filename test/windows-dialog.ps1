param([string] $PublicRef)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ui = [System.Windows.Automation.AutomationElement]
# Some Server WinForms providers expose native child controls as Pane. Send test input
# only to HWNDs owned by this installation of our dialog in the disposable runner.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DialogTest {
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, string l, uint flags, uint ms, out IntPtr result);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
}
'@
function Own-Handle($el) {
    $hwnd = [IntPtr]::new($el.Current.NativeWindowHandle)
    $ownerId = 0
    $null = [DialogTest]::GetWindowThreadProcessId($hwnd,[ref]$ownerId)
    if ($hwnd -eq [IntPtr]::Zero -or $ownerId -ne $dialog.Id) {throw 'Wrong dialog control owner'}
    return $hwnd
}
$app = Get-AppxPackage -Name OpenAI.Codex | Where-Object PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0'
$codex = Join-Path $app.InstallLocation 'app/resources/codex.exe'
$root = Join-Path $env:USERPROFILE ("sworncard-test-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -Type Directory $root
$acl = Get-Acl $root
$acl.SetAccessRuleProtection($true, $false)
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None','Allow'))
}
Set-Acl $root $acl
$env:TEMP = Join-Path $root 'temp'
$null = New-Item -Type Directory $env:TEMP
$env:TMP = $env:TEMP
$env:CODEX_HOME = Join-Path $root '.codex'
$env:CODEX_ELECTRON_USER_DATA_PATH = Join-Path $root 'desktop-data'
$env:SWORNCARD_CONNECT_PAT = $null
$exeName = 'SwornCardSetup.exe'
$workspace = $PWD.Path

function Wait-For([scriptblock] $condition, [string] $description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(50)
    do {
        $value = & $condition
        if ($value) { return $value }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $description"
}
function Element($window, [string] $name) {
    $byId = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new($ui::AutomationIdProperty,$name))
    if ($byId) { return $byId }
    # Older WinForms UIA providers expose Win32 IDs; match only children of this test-owned window.
    $found = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach ($child in $found) {
        $info = $child.Current
        if ($name -eq 'PersonalAccessToken' -and ($info.ControlType -eq [System.Windows.Automation.ControlType]::Edit -or $info.ClassName -like "WindowsForms*.EDIT.*")) {return $child}
        if ($name -eq 'Save' -and $info.Name -in @('Сохранить','Готово')) {return $child}
        if ($name -eq 'Cancel' -and $info.Name -eq 'Отмена') {return $child}
        if ($name -eq 'Status' -and ($info.ControlType -eq [System.Windows.Automation.ControlType]::Text -or $info.ClassName -like "WindowsForms*.STATIC.*") -and $info.Name -notlike 'Вставьте PAT*') {return $child}
    }
}
function Set-Field($element, [string]$value) {
    $result = [IntPtr]::Zero
    $sent = [DialogTest]::SendMessageTimeout((Own-Handle $element),0x000C,[IntPtr]::Zero,$value,2,3000,[ref]$result)
    if ($sent -eq [IntPtr]::Zero -or $result -eq [IntPtr]::Zero) {throw 'Test edit rejected input'}
}
function Click($element) {
    if (![DialogTest]::PostMessage((Own-Handle $element),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)) {throw 'Button did not receive test click'}
}
function New-Part {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Open-Setup {
    $script:dialog = Start-Process $installed -PassThru
    $hwnd = Wait-For { $dialog.Refresh(); if ($dialog.HasExited) {throw "Dialog exited: $($dialog.ExitCode)"}; if ($dialog.MainWindowHandle -ne 0) {$dialog.MainWindowHandle} } 'WinForms window'
    $window = $ui::FromHandle($hwnd)
    $field = Wait-For {Element $window 'PersonalAccessToken'} 'password edit control'
    if (([DialogTest]::GetWindowLong((Own-Handle $field),-16) -band 0x20) -eq 0) {throw 'Masked PAT field missing'}
    return $window
}

try {
    # Launch the installed Desktop on the empty runner, apart from the test's app-server RPC calls.
    $desktop = Start-Process (Join-Path $app.InstallLocation 'app/ChatGPT.exe') -PassThru
    $desktopWindow = Wait-For { (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {$_.MainWindowHandle -ne 0} | Select-Object -First 1) } 'official Desktop window'
    Write-Host "Opened clean official Codex Desktop $($app.Version)"
    if ($PublicRef) {
        & $codex plugin marketplace add https://github.com/idemnia/sworncard-connect-codex.git --ref $PublicRef
    } else { & $codex plugin marketplace add $workspace }
    if ($LASTEXITCODE) {throw 'Marketplace installation failed'}
    & $codex plugin add sworncard-connect@sworncard-connect
    if ($LASTEXITCODE) {throw 'Plugin installation failed'}
    $cache = Join-Path $env:CODEX_HOME 'plugins/cache/sworncard-connect/sworncard-connect'
    $versions = @(Get-ChildItem -LiteralPath $cache -Directory)
    if ($versions.Count -ne 1) {throw 'Expected a single installed plugin version in the clean profile'}
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $versions[0].FullName '.codex-plugin/plugin.json') | ConvertFrom-Json
    if ($manifest.name -ne 'sworncard-connect' -or $manifest.version -ne $versions[0].Name) {throw 'Installed manifest and cache disagree'}
    if ($PublicRef -and $PublicRef -ne "v$($manifest.version)") {throw 'The public release tag and installed plugin version disagree'}
    $installed = Join-Path $versions[0].FullName "skills/sworncard-setup/scripts/$exeName"
    if (!(Test-Path -LiteralPath $installed)) {throw 'Missing installed Windows dialog'}
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath (Join-Path $env:RUNNER_TEMP $exeName)).Hash) {
        throw 'Installed Windows dialog differs from the verified independent build'
    }
    $config = Join-Path $env:CODEX_HOME 'config.toml'
    # Model the field report: a separate Windows principal has inherited read/execute on config.toml.
    $observer = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-546')
    $acl = Get-Acl $env:CODEX_HOME
    $readRule = [Security.AccessControl.FileSystemAccessRule]::new($observer,'ReadAndExecute,Synchronize','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($readRule)
    Set-Acl $env:CODEX_HOME $acl
    $childRules = (Get-Acl $config).GetAccessRules($false,$true,[Security.Principal.SecurityIdentifier])
    if (!($childRules | Where-Object {$_.IdentityReference.Value -eq $observer.Value -and ($_.FileSystemRights -band 1)})) {throw 'Missing inherited sandbox-shaped read rule'}
    $original = (Get-FileHash $config).Hash
    $window = Open-Setup
    Click (Element $window 'Cancel')
    if (!$dialog.WaitForExit(5000) -or (Get-FileHash $config).Hash -ne $original) {throw 'Cancellation changed the configuration'}
    $id = 'pc_' + (New-Part)
    $old = ''
    $tokens = @()
    # A writable profile must still fail before a credential is staged.
    $fileAcl = Get-Acl $config
    $changed = Get-Acl $config
    $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($observer,'Write','Allow'))
    Set-Acl $config $changed
    try {
        $window = Open-Setup
        Set-Field (Element $window 'PersonalAccessToken') ('scpat1.' + $id + '.' + (New-Part))
        Click (Element $window 'Save')
        $null = Wait-For {(Element $window 'Status').Current.Name -like '*права записи*'} 'refusal on a writable config'
        Click (Element $window 'Cancel')
        if (!$dialog.WaitForExit(5000) -or (Get-FileHash $config).Hash -ne $original) {throw 'Writable configuration was changed'}
    } finally {Set-Acl $config $fileAcl}
    foreach ($stage in @('create','rotate','migrate')) {
        if ($stage -eq 'rotate') {
            # Model the previous release's working bundled server for this same connection.
            $env:SWORNCARD_CONNECT_PAT = $old
            $settings = [IO.File]::ReadAllText($config)
            $settings = $settings.Replace('enabled = false', 'enabled = true')
            [IO.File]::WriteAllText($config,$settings,[Text.UTF8Encoding]::new($false))
        }
        if ($stage -eq 'migrate') {
            # One old-format record, only in this disposable profile. No real credential is used.
            $settings = [IO.File]::ReadAllText($config)
            $legacyTable = "[mcp_servers.sworncard_$id.http_headers]`r`nAuthorization = `"Bearer $old`""
            $settings = [regex]::Replace($settings,'(?m)^http_headers_helper = [^\r\n]+','') + "`r`n$legacyTable`r`n"
            if (!$settings.Contains("Bearer $old")) {throw 'Missing synthetic legacy migration fixture'}
            [IO.File]::WriteAllText($config,$settings,[Text.UTF8Encoding]::new($false))
        }
        $window = Open-Setup
        $field = Element $window 'PersonalAccessToken'
        $button = Element $window 'Save'
        if ($stage -eq 'create') {
            Set-Field $field 'invalid'
            Click $button
            $null = Wait-For {(Element $window 'Status').Current.Name -like '*Скопируйте весь PAT*'} 'invalid input message'
            if ((Get-FileHash $config).Hash -ne $original) {throw 'Invalid token changed configuration'}
        }
        $token = 'scpat1.' + $id + '.' + (New-Part)
        Set-Field $field $token
        Click $button
        $null = Wait-For {
            $name = (Element $window 'Status').Current.Name
            if ($name -like '*сохранена*') { return $true }
            if ((Element $window 'Save').Current.IsEnabled -and $name -notlike '*будет сохранён*' -and $name -notlike '*Скопируйте*') {throw "Setup status: $name"}
        } 'confirmed save'
        Click (Element $window 'Save')
        if (!$dialog.WaitForExit(5000) -or $dialog.ExitCode -ne 0) {throw 'Setup did not close successfully'}
        $text = [IO.File]::ReadAllText($config)
        if (!$text.Contains("sworncard_$id") -or $text.Contains($token) -or !$text.Contains("http_headers_helper") -or !$text.Contains('https://connect.sworncard.ru/mcp') -or ($old -and $text.Contains($old))) {throw 'Personal configuration mismatch'}
        $tokens += $token
        $old = $token
        Write-Host "Passed Windows GUI step: $stage"
    }
    # A restarted process must actually authenticate. Use a loopback fixture; the installer pins the real RU URL.
    $env:SWORNCARD_CONNECT_PAT = $null
    # Stop the clean UI and its own child processes before inspecting the profile.
    if (!$desktopWindow.HasExited) {
        $null = $desktopWindow.CloseMainWindow()
        if (!$desktopWindow.WaitForExit(5000)) {
            & taskkill.exe /PID $desktopWindow.Id /T /F | Out-Null
            if (!$desktopWindow.WaitForExit(5000)) {throw 'Clean Desktop did not close'}
        }
    }
    ($tokens -join ' ') | python (Join-Path $PSScriptRoot 'windows-catalogue.py') $codex
    if ($LASTEXITCODE) {throw 'Catalogue check failed'}
} finally {
    if ($dialog -and !$dialog.HasExited) { $dialog.Kill() }
    if ($desktop -and !$desktop.HasExited) { $null = $desktop.CloseMainWindow() }
}
